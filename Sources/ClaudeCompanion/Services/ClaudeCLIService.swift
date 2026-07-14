import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ClaudeCLIService — pilotage du binaire `claude` via Process + Pipe
//
// Choix d'architecture : on N'ATTACHE PAS le TUI interactif (dont le stdout
// est un torrent de codes ANSI et de re-rendus impossibles à parser de façon
// fiable). On utilise le mode headless officiel :
//
//     claude -p --output-format stream-json --verbose --include-partial-messages
//
// → une ligne JSON par événement, streamable, stable. Le prompt est passé par
// STDIN (aucun problème d'échappement shell, longueur illimitée).
// stderr est capturé à part et nettoyé par ANSIStripper en cas d'erreur.
// ─────────────────────────────────────────────────────────────────────────────

/// Paramètres d'un tour de conversation.
struct CLIOptions: Sendable {
    let binary: URL
    let projectDirectory: URL
    /// Reprend une session existante (`--resume`). Attention : en mode -p, le
    /// CLI peut « forker » vers un NOUVEAU session_id — toujours lire l'id
    /// renvoyé par les événements init/result plutôt que de garder l'ancien.
    let resumeSessionID: String?
    let permissionMode: String
    let model: String?
    let includePartialMessages: Bool
}

enum CLIError: LocalizedError {
    case launchFailed(String)
    case processFailed(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Impossible de lancer le CLI claude : \(reason)"
        case .processFailed(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Le CLI claude a échoué (code \(code))." + (detail.isEmpty ? "" : "\n\(detail.suffix(600))")
        }
    }
}

/// `Process` n'est pas Sendable ; cette boîte permet de le partager en toute
/// connaissance de cause entre la tâche de lecture et le handler d'annulation
/// (les API utilisées — terminate/isRunning — sont thread-safe).
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

enum ClaudeCLIService {

    // MARK: - Localisation du binaire

    /// Les apps GUI macOS ne reçoivent PAS le PATH du shell de l'utilisateur
    /// (lancées depuis le Finder : PATH = /usr/bin:/bin:/usr/sbin:/sbin).
    /// On cherche donc `claude` aux emplacements d'installation connus, puis
    /// en dernier recours via un shell de connexion (qui charge nvm, asdf…).
    ///
    /// ⚠️ Appel bloquant (repli shell) : à invoquer hors du MainActor.
    static func locateBinary() -> URL? {
        let fm = FileManager.default

        // 1. Chemin forcé par l'utilisateur :
        //    defaults write <bundle-id> claudeBinaryPath /chemin/vers/claude
        if let override = UserDefaults.standard.string(forKey: "claudeBinaryPath"),
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        // 2. Emplacements d'installation habituels.
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",        // installeur natif (défaut actuel)
            "\(home)/.claude/local/claude",     // ancien installeur natif
            "/opt/homebrew/bin/claude",         // Homebrew (Apple Silicon)
            "/usr/local/bin/claude",            // Homebrew (Intel) / npm -g
            "\(home)/.bun/bin/claude",          // bun
            "\(home)/.npm-global/bin/claude",   // npm prefix personnalisé
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // 3. Repli : shell de connexion. `-l` charge ~/.zprofile (nvm & co).
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-l", "-c", "command -v claude"]
        let stdout = Pipe()
        probe.standardOutput = stdout
        probe.standardError = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0,
               let data = try stdout.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        } catch {
            // ignoré — on renvoie nil plus bas
        }
        return nil
    }

    // MARK: - Streaming d'un tour

    /// Lance un tour de conversation et renvoie les événements au fil de l'eau.
    ///
    /// Annulation : annuler la tâche qui itère le flux (ou casser l'itération)
    /// envoie SIGTERM au processus via `onTermination` → le CLI s'arrête
    /// proprement et le flux se termine sans erreur.
    static func events(prompt: String, options: CLIOptions) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()

            let worker = Task.detached(priority: .userInitiated) {
                let process = box.process
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()

                process.executableURL = options.binary
                process.arguments = arguments(for: options)
                process.currentDirectoryURL = options.projectDirectory
                process.environment = environment(for: options.binary)
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                // Continuation de sortie installée AVANT run() → aucune course
                // possible entre la fin du processus et notre attente.
                let (exitStatuses, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
                process.terminationHandler = { p in
                    exitContinuation.yield(p.terminationStatus)
                    exitContinuation.finish()
                }

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: CLIError.launchFailed(error.localizedDescription))
                    return
                }

                await withTaskCancellationHandler {
                    // Prompt via stdin, dans une sous-tâche : un gros prompt
                    // pourrait dépasser le tampon du pipe (64 Ko) et bloquer.
                    let promptData = Data(prompt.utf8)
                    Task.detached {
                        let handle = stdinPipe.fileHandleForWriting
                        try? handle.write(contentsOf: promptData)
                        try? handle.close() // EOF → le CLI sait que le prompt est complet
                    }

                    // stderr lu EN PARALLÈLE de stdout : si on le laissait se
                    // remplir, le processus se bloquerait sur un pipe plein.
                    async let stderrText = collect(stderrPipe.fileHandleForReading)

                    // Lecture ligne à ligne du JSONL, 100 % asynchrone.
                    do {
                        for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                            for event in ClaudeEventDecoder.decode(line: line) {
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        // Lecture interrompue (processus tué…) : le code de
                        // sortie ci-dessous décidera du verdict.
                    }

                    var status: Int32 = -1
                    for await code in exitStatuses { status = code }
                    let errText = await stderrText

                    if Task.isCancelled {
                        continuation.finish() // arrêt volontaire, pas une erreur
                    } else if status != 0 {
                        continuation.finish(throwing: CLIError.processFailed(
                            code: status,
                            stderr: ANSIStripper.strip(errText)
                        ))
                    } else {
                        continuation.finish()
                    }
                } onCancel: {
                    if box.process.isRunning { box.process.terminate() }
                }
            }

            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    // MARK: - Construction de la ligne de commande

    static func arguments(for options: CLIOptions) -> [String] {
        var args = [
            "--print",                        // mode headless (équivalent -p)
            "--output-format", "stream-json", // JSONL événementiel
            "--verbose",                      // requis par stream-json en mode --print
        ]
        if options.includePartialMessages {
            args.append("--include-partial-messages") // deltas de texte token par token
        }
        if let sessionID = options.resumeSessionID {
            args += ["--resume", sessionID]
        }
        args += ["--permission-mode", options.permissionMode]
        if let model = options.model {
            args += ["--model", model]
        }
        return args
    }

    /// Environnement du processus : PATH enrichi (le CLI npm a besoin de
    /// trouver `node`, souvent installé à côté de lui) + sortie sans couleurs.
    static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binaryDir = binary.deletingLastPathComponent().path
        let resolvedDir = binary.resolvingSymlinksInPath().deletingLastPathComponent().path
        let extra = [
            binaryDir, resolvedDir,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var seen = Set<String>()
        let merged = (extra + (env["PATH"] ?? "").components(separatedBy: ":"))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        env["NO_COLOR"] = "1" // limite les codes ANSI parasites sur stderr
        return env
    }

    private static func collect(_ handle: FileHandle) async -> String {
        var output = ""
        do {
            for try await line in handle.bytes.lines {
                output += line + "\n"
            }
        } catch {
            // fin de flux abrupte : on garde ce qu'on a
        }
        return output
    }
}

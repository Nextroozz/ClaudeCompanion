import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SessionHistoryService — lecture des sessions persistées par Claude Code
//
// Claude Code journalise chaque session dans :
//     ~/.claude/projects/<chemin-encodé-du-projet>/<session-id>.jsonl
//
// C'est la source de vérité pour l'historique : on peut relister les sessions
// d'un projet, en recharger une dans l'UI, puis la poursuivre via `--resume`.
// Le schéma des lignes réutilise StreamEnvelope (mêmes DTO que le flux live).
// ─────────────────────────────────────────────────────────────────────────────

/// Une session listée dans le menu « Historique ».
struct SessionSummary: Identifiable, Sendable {
    let id: String          // session_id == nom du fichier sans extension
    let fileURL: URL
    let modifiedAt: Date
    let title: String
}

enum SessionHistoryService {

    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Encodage du chemin projet utilisé par Claude Code pour nommer le
    /// dossier : tout caractère non alphanumérique devient un tiret.
    /// Ex. « /Users/max/Desktop/Claude code test » → « -Users-max-Desktop-Claude-code-test »
    static func encodedDirectoryName(for projectDirectory: URL) -> String {
        String(projectDirectory.standardizedFileURL.path.map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
    }

    static func sessionsDirectory(for projectDirectory: URL) -> URL {
        projectsRoot.appendingPathComponent(encodedDirectoryName(for: projectDirectory), isDirectory: true)
    }

    // MARK: - Liste des sessions

    static func listSessions(for projectDirectory: URL) -> [SessionSummary] {
        let directory = sessionsDirectory(for: projectDirectory)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> SessionSummary? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return SessionSummary(
                    id: url.deletingPathExtension().lastPathComponent,
                    fileURL: url,
                    modifiedAt: date,
                    title: sessionTitle(at: url)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Titre lisible : la ligne {"type":"summary"} si présente, sinon le
    /// premier message utilisateur. On ne lit que le début du fichier
    /// (512 Ko) — largement assez pour un titre, même sur de grosses sessions.
    private static func sessionTitle(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Session" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024),
              let text = String(data: data, encoding: .utf8) else { return "Session" }

        var firstUserText: String?
        for line in text.split(separator: "\n").prefix(200) {
            guard let lineData = line.data(using: .utf8),
                  let envelope = try? ClaudeEventDecoder.jsonDecoder.decode(StreamEnvelope.self, from: lineData)
            else { continue }

            if envelope.type == "summary", let summary = envelope.summary, !summary.isEmpty {
                return truncatedTitle(summary) // le résumé généré par Claude prime
            }
            if firstUserText == nil,
               envelope.type == "user",
               envelope.isMeta != true, envelope.isSidechain != true,
               let text = primaryUserText(of: envelope),
               !isCommandNoise(text) {
                firstUserText = text
            }
        }
        return truncatedTitle(firstUserText ?? "Session")
    }

    // MARK: - Chargement d'une session complète

    static func loadMessages(from fileURL: URL) -> [ChatMessage] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var messages: [ChatMessage] = []

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? ClaudeEventDecoder.jsonDecoder.decode(StreamEnvelope.self, from: data),
                  envelope.isMeta != true, envelope.isSidechain != true
            else { continue }

            switch envelope.type {
            case "user":
                guard let text = primaryUserText(of: envelope), !isCommandNoise(text) else { continue }
                messages.append(ChatMessage(
                    id: envelope.uuid ?? UUID().uuidString,
                    role: .user,
                    segments: [.text(text)]
                ))

            case "assistant":
                guard let message = envelope.message else { continue }
                // Dans l'historique, tous les outils sont terminés.
                let segments = ClaudeEventDecoder.mapSegments(message.content).map { segment -> ChatMessage.Segment in
                    if case .tool(var call) = segment {
                        call.status = .done
                        return .tool(call)
                    }
                    return segment
                }
                guard !segments.isEmpty else { continue }
                // Le JSONL écrit parfois UNE ligne PAR bloc de contenu, avec le
                // même id de message API : on fusionne pour reconstituer le tour.
                let apiID = message.id ?? envelope.uuid ?? UUID().uuidString
                if let lastIndex = messages.indices.last,
                   messages[lastIndex].role == .assistant,
                   messages[lastIndex].id == apiID {
                    messages[lastIndex].segments.append(contentsOf: segments)
                } else {
                    messages.append(ChatMessage(id: apiID, role: .assistant, segments: segments))
                }

            default:
                continue // summary, file-history-snapshot, etc.
            }
        }
        return messages
    }

    // MARK: - Helpers

    /// Extrait le texte « humain » d'une ligne user (chaîne brute ou blocs texte,
    /// en ignorant les tool_result).
    private static func primaryUserText(of envelope: StreamEnvelope) -> String? {
        switch envelope.message?.content {
        case .text(let string):
            return string.isEmpty ? nil : string
        case .blocks(let blocks):
            let texts = blocks.compactMap { $0.type == "text" ? $0.text : nil }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        case nil:
            return nil
        }
    }

    /// Écarte le bruit technique présent dans les JSONL (commandes locales,
    /// avertissements d'interface…), sans valeur pour l'utilisateur.
    private static func isCommandNoise(_ text: String) -> Bool {
        text.hasPrefix("<command-") ||
        text.hasPrefix("<local-command") ||
        text.hasPrefix("Caveat:") ||
        text.contains("<command-name>")
    }

    private static func truncatedTitle(_ string: String, limit: Int = 64) -> String {
        let oneLine = string
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}

// MARK: - Surveillance du dossier de sessions

/// Observe un dossier via DispatchSource et notifie à chaque écriture —
/// permet de rafraîchir le menu Historique quand Claude Code (cette app ou le
/// terminal) écrit de nouvelles lignes de session.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fileDescriptor: Int32

    init?(url: URL, onChange: @escaping () -> Void) {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        let fd = fileDescriptor
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

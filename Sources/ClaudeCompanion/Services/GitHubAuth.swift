import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// GitHubAuth — jeton pour la recherche de code (Phase 2)
//
// L'API code-search de GitHub EXIGE une authentification (l'anonyme est refusé).
// Plutôt que de demander un token à l'utilisateur, on réutilise celui de son
// `gh` déjà connecté : `gh auth token`. Zéro configuration si `gh` est présent ;
// sinon la recherche est simplement indisponible, avec un message clair.
//
// Le binaire `gh` est localisé comme `claude` l'est (une app GUI n'hérite pas du
// PATH du shell) : emplacements usuels puis repli via un shell de connexion.
// ─────────────────────────────────────────────────────────────────────────────

enum GitHubAuth {

    /// Jeton mémorisé le temps de la session : `gh auth token` est un sous-
    /// processus, inutile de le relancer à chaque frappe dans la recherche.
    private static var cachedToken: String?

    /// Renvoie un token OAuth GitHub, ou nil si `gh` est absent/déconnecté.
    /// ⚠️ Lance un sous-processus : à appeler hors du MainActor.
    static func token() -> String? {
        if let cachedToken { return cachedToken }
        guard let gh = locateBinary() else { return nil }

        let process = Process()
        process.executableURL = gh
        process.arguments = ["auth", "token"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try stdout.fileHandleForReading.readToEnd(),
                  let token = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            cachedToken = token
            return token
        } catch {
            return nil
        }
    }

    /// `gh` est-il utilisable ? (présent ET connecté)
    static var isAvailable: Bool { token() != nil }

    private static func locateBinary() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/gh",   // Homebrew (Apple Silicon)
            "/usr/local/bin/gh",      // Homebrew (Intel)
            "\(home)/.local/bin/gh",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Repli : shell de connexion (charge ~/.zprofile).
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-l", "-c", "command -v gh"]
        let stdout = Pipe()
        probe.standardOutput = stdout
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return nil }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

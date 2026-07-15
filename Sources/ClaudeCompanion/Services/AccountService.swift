import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// AccountService — compte Anthropic connecté au CLI
//
// Le CLI persiste le compte OAuth dans ~/.claude.json (clé "oauthAccount") :
// on y lit l'identité affichée dans le menu (email, organisation, tier),
// sans appel réseau. Actions :
//   • Déconnexion : `claude auth logout` — non interactif, exécuté en Process.
//   • Connexion : `claude auth login` est un flux OAuth interactif (navigateur
//     + confirmation dans le terminal) — on l'ouvre dans Terminal.app via un
//     fichier .command, ce qui ne requiert AUCUNE permission d'automatisation.
// ─────────────────────────────────────────────────────────────────────────────

struct AccountInfo: Equatable {
    let email: String?
    let displayName: String?
    let organization: String?
    let planHint: String?   // seatTier / rate-limit tier / type de facturation
}

enum AccountService {

    /// Lit le compte connecté depuis ~/.claude.json. nil = déconnecté.
    static func currentAccount() -> AccountInfo? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              !account.isEmpty
        else { return nil }

        let plan = (root["subscriptionType"] as? String)
            ?? (account["seatTier"] as? String)
            ?? (account["userRateLimitTier"] as? String)
            ?? (account["billingType"] as? String)

        return AccountInfo(
            email: account["emailAddress"] as? String,
            displayName: account["displayName"] as? String,
            organization: account["organizationName"] as? String,
            planHint: plan
        )
    }

    /// `claude auth logout`. Renvoie nil en cas de succès, sinon le message
    /// d'erreur. ⚠️ Bloquant : à appeler hors du MainActor.
    static func logout(binary: URL) -> String? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["auth", "logout"]
        process.environment = ClaudeCLIService.environment(for: binary)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return "Impossible de lancer le CLI : \(error.localizedDescription)"
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let text = ANSIStripper.strip(String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Échec de la déconnexion (code \(process.terminationStatus))." : text
    }

    /// Ouvre `claude auth login` dans Terminal.app (fichier .command exécutable).
    static func openLoginInTerminal(binary: URL) throws {
        let script = """
        #!/bin/zsh
        clear
        echo "── Connexion à Claude Code ─────────────────────────────"
        echo "Suivez les instructions ci-dessous (le navigateur va s'ouvrir)."
        echo ""
        "\(binary.path)" auth login
        echo ""
        echo "Terminé — vous pouvez fermer cette fenêtre et rouvrir le menu compte dans Claude Companion."
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-companion-login.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

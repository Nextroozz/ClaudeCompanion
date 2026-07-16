import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// GitHubFetch — GET anonyme partagé (catalogue + installation)
//
// GitHub exige un User-Agent, sinon 403. On centralise ici pour ne pas répéter
// l'en-tête et le timeout, et pour offrir un point unique où brancher, en
// Phase 2, un token (recherche code-search, quotas plus élevés).
// ─────────────────────────────────────────────────────────────────────────────

enum GitHubFetch {

    /// GET brut. Renvoie nil sur tout code ≠ 200 ou erreur réseau.
    static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("ClaudeCompanion", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Raw d'un fichier du dépôt (hors quota de l'API).
    static func rawURL(repo: String, branch: String = "main", path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(path)")!
    }
}

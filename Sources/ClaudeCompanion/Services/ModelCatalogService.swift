import Foundation
import Security

// ─────────────────────────────────────────────────────────────────────────────
// ModelCatalogService — liste des modèles Claude disponibles
//
// Source dynamique : GET https://api.anthropic.com/v1/models, authentifié avec
// le token OAuth que Claude Code garde dans le Trousseau (item générique
// « Claude Code-credentials »). Les nouveaux modèles apparaissent donc dans le
// sélecteur dès leur sortie, sans mise à jour de l'app.
//
// macOS affichera UNE demande d'accès au Trousseau à la première lecture
// (« ClaudeCompanion veut accéder… ») — refuser ne casse rien : on retombe
// sur une liste statique raisonnable, rafraîchie à chaque release de l'app.
// ─────────────────────────────────────────────────────────────────────────────

/// Un modèle sélectionnable dans le menu.
struct ClaudeModel: Identifiable, Sendable, Equatable, Codable {
    let id: String          // "claude-opus-4-8" — passé tel quel à --model
    let displayName: String // "Claude Opus 4.8"
}

enum ModelCatalogService {

    /// Repli si l'API est injoignable ou le Trousseau refusé.
    static let fallbackModels: [ClaudeModel] = [
        .init(id: "claude-fable-5",   displayName: "Claude Fable 5"),
        .init(id: "claude-opus-4-8",  displayName: "Claude Opus 4.8"),
        .init(id: "claude-opus-4-7",  displayName: "Claude Opus 4.7"),
        .init(id: "claude-opus-4-6",  displayName: "Claude Opus 4.6"),
        .init(id: "claude-sonnet-5",  displayName: "Claude Sonnet 5"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    private static let cacheKey = "modelCatalogCache"
    private static let cacheDateKey = "modelCatalogCacheDate"
    private static let cacheLifetime: TimeInterval = 6 * 3600

    /// Liste immédiatement affichable : cache récent, sinon repli statique.
    static func cachedModels() -> [ClaudeModel] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let models = try? JSONDecoder().decode([ClaudeModel].self, from: data),
              !models.isEmpty else { return fallbackModels }
        return models
    }

    /// Rafraîchit depuis l'API si le cache a expiré. Renvoie la liste à jour
    /// (ou celle du cache/repli en cas d'échec). ⚠️ Réseau + Trousseau :
    /// à appeler hors du MainActor.
    static func refreshedModels() async -> [ClaudeModel] {
        let lastRefresh = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < cacheLifetime {
            return cachedModels()
        }
        guard let fetched = await fetchFromAPI(), !fetched.isEmpty else {
            return cachedModels()
        }
        if let data = try? JSONEncoder().encode(fetched) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
        return fetched
    }

    // MARK: - API

    private static func fetchFromAPI() async -> [ClaudeModel]? {
        guard let token = oauthAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=50")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        struct ModelsResponse: Decodable {
            struct Entry: Decodable {
                let id: String
                let displayName: String?
            }
            let data: [Entry]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let list = try? decoder.decode(ModelsResponse.self, from: data) else { return nil }
        return list.data.map {
            ClaudeModel(id: $0.id, displayName: $0.displayName ?? ModelNames.short($0.id))
        }
    }

    /// Token OAuth de Claude Code, stocké dans le Trousseau sous l'item
    /// générique « Claude Code-credentials » (JSON avec claudeAiOauth.accessToken).
    private static func oauthAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = root["claudeAiOauth"] as? [String: Any]
        return (oauth?["accessToken"] as? String) ?? (root["accessToken"] as? String)
    }
}

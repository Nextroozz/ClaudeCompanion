import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillCatalogService — le catalogue OFFICIEL (anthropics/skills)
//
// Source curée et sûre : le dépôt public github.com/anthropics/skills. On liste
// ses skills via l'API contents (1 appel, anonyme), puis on lit chaque
// description via raw.githubusercontent.com — qui n'est PAS soumis au quota de
// l'API. Résultat mis en cache 24 h : un catalogue qui bouge rarement n'a pas à
// être rechargé à chaque ouverture du panneau.
//
// Anonyme volontairement : le catalogue officiel est public et la Phase 1 évite
// toute authentification. La recherche GitHub large (69 k skills) viendra en
// Phase 2, elle, avec l'auth qu'impose l'API code-search.
// ─────────────────────────────────────────────────────────────────────────────

enum SkillCatalogService {

    static let repo = "anthropics/skills"

    private static let cacheKey = "skillCatalogCache"
    private static let cacheDateKey = "skillCatalogCacheDate"
    private static let cacheLifetime: TimeInterval = 24 * 3600

    /// Entrée de cache minimale : on ne persiste que le strict nécessaire pour
    /// reconstruire des Skill, sans rendre tout le graphe Codable.
    private struct CatalogEntry: Codable {
        let name: String
        let description: String
    }

    /// Catalogue immédiatement affichable depuis le cache (vide si jamais chargé).
    static func cachedCatalog() -> [Skill] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([CatalogEntry].self, from: data) else {
            return []
        }
        return entries.map { Skill(name: $0.name, description: $0.description,
                                   origin: .official, installed: nil) }
    }

    /// Rafraîchit depuis GitHub si le cache a expiré. ⚠️ Réseau : hors MainActor.
    static func refreshedCatalog() async -> [Skill] {
        let last = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        if let last, Date().timeIntervalSince(last) < cacheLifetime {
            let cached = cachedCatalog()
            if !cached.isEmpty { return cached }
        }
        guard let fetched = await fetchCatalog(), !fetched.isEmpty else {
            return cachedCatalog() // repli : mieux vaut un cache vieux que rien
        }
        let entries = fetched.map { CatalogEntry(name: $0.name, description: $0.description) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
        return fetched
    }

    // MARK: - Réseau

    /// Liste les dossiers de `skills/`, puis lit chaque SKILL.md en parallèle.
    private static func fetchCatalog() async -> [Skill]? {
        guard let names = await listSkillNames() else { return nil }

        return await withTaskGroup(of: Skill?.self) { group in
            for name in names {
                group.addTask { await fetchSkill(named: name) }
            }
            var skills: [Skill] = []
            for await skill in group {
                if let skill { skills.append(skill) }
            }
            return skills.sorted { $0.name < $1.name }
        }
    }

    /// Sous-dossiers de `skills/` via l'API contents (anonyme).
    private static func listSkillNames() async -> [String]? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/contents/skills")!
        guard let data = await get(url) else { return nil }

        struct Entry: Decodable { let name: String; let type: String }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries.filter { $0.type == "dir" }.map(\.name)
    }

    /// Description d'un skill par lecture de son SKILL.md brut (hors quota API).
    private static func fetchSkill(named name: String) async -> Skill? {
        let url = GitHubFetch.rawURL(repo: repo, path: "skills/\(name)/SKILL.md")
        guard let data = await GitHubFetch.get(url),
              let content = String(data: data, encoding: .utf8),
              let meta = SkillFrontmatter.parse(content) else { return nil }
        return Skill(name: meta.name, description: meta.description,
                     origin: .official, installed: nil)
    }

    private static func get(_ url: URL) async -> Data? { await GitHubFetch.get(url) }
}

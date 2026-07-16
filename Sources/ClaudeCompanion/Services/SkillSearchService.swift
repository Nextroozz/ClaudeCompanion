import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillSearchService — recherche de skills sur TOUT GitHub (Phase 2)
//
// Interroge l'API code-search (`filename:SKILL.md` + les termes de l'utilisateur)
// avec le token de `gh` (voir GitHubAuth). Chaque résultat est un SKILL.md
// quelque part ; le dossier qui le contient EST le skill. On lit le frontmatter
// via raw pour nom + description, et on retient de quoi l'installer.
//
// Ces skills sont NON VÉRIFIÉS : l'UI les badge en conséquence et l'aperçu +
// l'alerte scripts (déjà en place) restent le garde-fou avant toute install.
// ─────────────────────────────────────────────────────────────────────────────

enum SkillSearchService {

    enum SearchError: LocalizedError {
        case noAuth
        case requestFailed

        var errorDescription: String? {
            switch self {
            case .noAuth:        return "Recherche GitHub indisponible : installez « gh » et connectez-vous (gh auth login)."
            case .requestFailed: return "La recherche GitHub a échoué (quota atteint ou réseau ?)."
            }
        }
    }

    /// Recherche les skills correspondant à `query`. ⚠️ Réseau + sous-processus
    /// (token) : hors MainActor.
    static func search(_ query: String) async throws -> [Skill] {
        guard let token = GitHubAuth.token() else { throw SearchError.noAuth }

        let terms = query.trimmingCharacters(in: .whitespaces)
        // Le qualificatif filename cible les SKILL.md ; les termes ajoutent le sujet.
        let q = (terms.isEmpty ? "" : terms + " ") + "filename:SKILL.md"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.github.com/search/code?q=\(encoded)&per_page=30")
        else { throw SearchError.requestFailed }

        guard let data = await GitHubFetch.get(url, token: token,
                                               accept: "application/vnd.github+json") else {
            throw SearchError.requestFailed
        }

        struct Response: Decodable {
            struct Item: Decodable {
                struct Repo: Decodable { let fullName: String }
                let path: String
                let htmlUrl: String
                let repository: Repo
            }
            let items: [Item]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data) else {
            throw SearchError.requestFailed
        }

        // Dédup par dépôt+dossier : un même skill ne doit pas apparaître deux fois.
        var seen = Set<String>()
        let sources: [Skill.CommunitySource] = response.items.compactMap { item in
            guard let ref = referenceFromBlobURL(item.htmlUrl) else { return nil }
            let folder = folderPath(of: item.path)
            let key = item.repository.fullName + "/" + folder
            guard seen.insert(key).inserted else { return nil }
            return Skill.CommunitySource(repo: item.repository.fullName, ref: ref, folderPath: folder)
        }

        // Lecture des frontmatters en parallèle → Skills communautaires.
        return await withTaskGroup(of: Skill?.self) { group in
            for source in sources {
                group.addTask { await skill(from: source) }
            }
            var skills: [Skill] = []
            for await skill in group { if let skill { skills.append(skill) } }
            return skills.sorted { $0.name < $1.name }
        }
    }

    /// Frontmatter d'un SKILL.md communautaire → Skill.
    private static func skill(from source: Skill.CommunitySource) async -> Skill? {
        let path = source.folderPath.isEmpty ? "SKILL.md" : source.folderPath + "/SKILL.md"
        let url = GitHubFetch.rawURL(repo: source.repo, branch: source.ref, path: path)
        guard let data = await GitHubFetch.get(url),
              let content = String(data: data, encoding: .utf8),
              let meta = SkillFrontmatter.parse(content) else { return nil }
        return Skill(name: meta.name, description: meta.description,
                     origin: .community(source), installed: nil)
    }

    // MARK: - Analyse des résultats

    /// Le dossier contenant le SKILL.md (chemin sans le dernier segment).
    /// "" pour un SKILL.md à la racine du dépôt.
    static func folderPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Extrait la révision d'une html_url de blob : .../blob/<ref>/<chemin…>.
    /// GitHub y met le SHA du commit — idéal, l'install pointera exactement ce
    /// qu'on a prévisualisé, insensible à un push ultérieur.
    static func referenceFromBlobURL(_ urlString: String) -> String? {
        guard let range = urlString.range(of: "/blob/") else { return nil }
        let after = urlString[range.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return nil }
        let ref = String(after[after.startIndex..<slash])
        return ref.isEmpty ? nil : ref
    }
}

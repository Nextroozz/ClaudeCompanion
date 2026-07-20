import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillSuggester — propositions selon le contenu du projet
//
// Déterministe et gratuit : on lit quelques signaux du dossier projet (langages,
// frameworks, types de fichiers) et on les mappe vers les skills du catalogue.
// Aucun appel modèle — c'est instantané et sans coût. La suggestion assistée par
// le CLI (« vu ces fichiers, quoi d'utile ? ») est prévue en Phase 3.
//
// La DÉTECTION (lecture disque) est séparée du MAPPAGE (pur) : ce dernier se
// teste sans toucher au système de fichiers.
// ─────────────────────────────────────────────────────────────────────────────

/// Ce qu'on retient d'un projet pour raisonner sur les skills utiles.
struct ProjectSignals: Equatable {
    var fileExtensions: Set<String> = []   // en minuscules, sans point : "tsx", "pdf"…
    var hasReact = false                   // react/next repéré dans package.json
    var usesMCP = false                    // .mcp.json ou dépendance MCP
    var buildsSkills = false               // un SKILL.md vit déjà dans le projet
    var usesAnthropicSDK = false           // dépendance @anthropic-ai / anthropic
    /// Langage dominant, exprimé en terme de recherche ("swift", "python"…).
    /// C'est le repli qui rend les suggestions communautaires utiles sur
    /// N'IMPORTE quel projet, pas seulement web/JS.
    var primaryLanguage: String?
}

/// Extensions de CODE → terme de recherche. Sert à la fois à repérer la langue
/// dominante et à formuler une requête GitHub. Les fichiers hors de cette table
/// (.md, .json, .yml…) ne sont pas des langages et sont ignorés.
enum CodeLanguage {
    static let byExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "tsx": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript",
        "py": "python",
        "rs": "rust",
        "go": "golang",
        "java": "java", "kt": "kotlin",
        "rb": "ruby", "php": "php",
        "cs": "csharp",
        "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
        "c": "c", "h": "c",
        "sh": "bash", "bash": "bash",
        "lua": "lua", "dart": "dart", "ex": "elixir", "exs": "elixir",
    ]
}

/// Un skill proposé, avec la raison — l'UI l'affiche pour que la suggestion soit
/// compréhensible plutôt que magique.
struct SkillSuggestion: Identifiable, Equatable {
    let skill: Skill
    let reason: String
    var id: String { skill.name }
}

enum SkillSuggester {

    /// Règle : un prédicat sur les signaux → des noms de skills + une raison.
    private struct Rule {
        let matches: (ProjectSignals) -> Bool
        let skillNames: [String]
        let reason: String
    }

    private static let rules: [Rule] = [
        Rule(matches: { $0.hasReact || $0.fileExtensions.contains("tsx") || $0.fileExtensions.contains("jsx") },
             skillNames: ["frontend-design", "web-artifacts-builder"],
             reason: "Projet d'interface web détecté"),
        Rule(matches: { $0.hasReact },
             skillNames: ["webapp-testing"],
             reason: "Application web — tests de bout en bout"),
        Rule(matches: { $0.usesMCP },
             skillNames: ["mcp-builder"],
             reason: "Serveur MCP dans le projet"),
        Rule(matches: { $0.usesAnthropicSDK },
             skillNames: ["claude-api"],
             reason: "SDK Anthropic utilisé"),
        Rule(matches: { $0.buildsSkills },
             skillNames: ["skill-creator"],
             reason: "Vous créez déjà des skills ici"),
        Rule(matches: { $0.fileExtensions.contains("pdf") },
             skillNames: ["pdf"], reason: "Fichiers PDF présents"),
        Rule(matches: { $0.fileExtensions.contains("docx") },
             skillNames: ["docx"], reason: "Documents Word présents"),
        Rule(matches: { $0.fileExtensions.contains("xlsx") },
             skillNames: ["xlsx"], reason: "Feuilles Excel présentes"),
        Rule(matches: { $0.fileExtensions.contains("pptx") },
             skillNames: ["pptx"], reason: "Présentations PowerPoint présentes"),
    ]

    /// Mappage PUR : signaux + catalogue → suggestions, hors skills déjà
    /// installés (inutile de proposer ce qu'on a déjà). L'ordre des règles fait
    /// l'ordre d'affichage ; un même skill n'est proposé qu'une fois.
    static func suggestions(for signals: ProjectSignals,
                            catalog: [Skill],
                            installed: Set<String>) -> [SkillSuggestion] {
        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [SkillSuggestion] = []

        for rule in rules where rule.matches(signals) {
            for name in rule.skillNames {
                guard !installed.contains(name), !seen.contains(name),
                      let skill = byName[name] else { continue }
                seen.insert(name)
                result.append(SkillSuggestion(skill: skill, reason: rule.reason))
            }
        }
        return result
    }

    /// Requête GitHub dérivée du signal projet le PLUS fort, pour aller chercher
    /// des skills communautaires pertinents (Phase 2). Pur : le ViewModel lance
    /// la recherche. Un seul terme, du plus spécifique au plus général — inutile
    /// de noyer l'utilisateur sous dix recherches.
    static func communityQuery(for signals: ProjectSignals) -> (query: String, reason: String)? {
        if signals.usesMCP {
            return ("mcp server", "Serveur MCP — skills de la communauté")
        }
        if signals.usesAnthropicSDK {
            return ("anthropic claude api", "API Claude — skills de la communauté")
        }
        if signals.hasReact {
            return ("react component", "Projet React — skills de la communauté")
        }
        // Repli général : le langage dominant du projet, quel qu'il soit.
        // C'est ce qui fait qu'un projet Swift, Java ou Rust obtient enfin des
        // suggestions, là où l'ancienne liste codée en dur ne couvrait que JS/py.
        if let language = signals.primaryLanguage {
            return (language, "Projet \(language.capitalized) — skills de la communauté")
        }
        return nil
    }

    // MARK: - Détection (lecture disque)

    /// Parcourt le projet en surface (profondeur limitée : un scan récursif
    /// complet serait lent sur un gros dépôt, et les signaux utiles sont en
    /// général près de la racine).
    static func detectSignals(in projectDirectory: URL) -> ProjectSignals {
        var signals = ProjectSignals()
        let fm = FileManager.default

        // package.json à la racine : react/next, MCP, SDK Anthropic.
        let packageJSON = projectDirectory.appendingPathComponent("package.json")
        if let text = try? String(contentsOf: packageJSON, encoding: .utf8) {
            let lower = text.lowercased()
            signals.hasReact = lower.contains("\"react\"") || lower.contains("\"next\"")
            signals.usesMCP = lower.contains("modelcontextprotocol") || lower.contains("\"mcp")
            signals.usesAnthropicSDK = lower.contains("@anthropic-ai")
        }
        if fm.fileExists(atPath: projectDirectory.appendingPathComponent(".mcp.json").path) {
            signals.usesMCP = true
        }
        // requirements.txt / pyproject : SDK Anthropic côté Python.
        for pyDep in ["requirements.txt", "pyproject.toml"] {
            if let text = try? String(contentsOf: projectDirectory.appendingPathComponent(pyDep), encoding: .utf8),
               text.lowercased().contains("anthropic") {
                signals.usesAnthropicSDK = true
            }
        }

        // Extensions présentes (profondeur 2) + repérage d'un SKILL.md +
        // décompte des fichiers de code pour dégager la langue dominante.
        var languageCounts: [String: Int] = [:]
        if let enumerator = fm.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 4000 { break } // garde-fou sur les très gros dépôts
                if enumerator.level > 2 { enumerator.skipDescendants(); continue }
                if url.lastPathComponent == "SKILL.md" { signals.buildsSkills = true }
                let ext = url.pathExtension.lowercased()
                guard !ext.isEmpty else { continue }
                signals.fileExtensions.insert(ext)
                if let language = CodeLanguage.byExtension[ext] {
                    languageCounts[language, default: 0] += 1
                }
            }
        }
        // La langue la plus fréquente l'emporte ; à égalité, l'ordre
        // alphabétique tranche pour rester déterministe (utile aux tests).
        signals.primaryLanguage = languageCounts
            .max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        return signals
    }
}

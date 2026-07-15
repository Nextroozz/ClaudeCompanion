import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SlashCommandService — commandes « / » disponibles pour l'autocomplétion
//
// SOURCE DE VÉRITÉ : l'événement init du flux stream-json expose
// `slash_commands` — la liste complète et à jour de ce que CE CLI accepte
// (intégrées, plugins, skills, commandes perso). Le ViewModel la capte à
// chaque tour et la persiste, donc elle survit aux relances de l'app.
//
// Ce service fournit le reste : les DESCRIPTIONS. Intégrées → table locale ;
// plugins → frontmatter des .md dans ~/.claude/plugins/cache ; commandes et
// skills perso → .claude/commands & .claude/skills (projet et utilisateur).
// ─────────────────────────────────────────────────────────────────────────────

/// Une commande proposée dans l'autocomplétion de la barre de saisie.
struct SlashCommand: Identifiable, Sendable, Equatable {
    let name: String        // sans le « / » (ex. "compact", "vercel:deploy")
    let description: String

    var id: String { name }
    /// Texte inséré dans le champ quand la suggestion est acceptée.
    var insertionText: String { "/\(name) " }
}

enum SlashCommandService {

    /// Descriptions des commandes intégrées de Claude Code (celles qui ont un
    /// sens en mode headless — les autres reçoivent une description générique).
    static let builtinDescriptions: [String: String] = [
        "compact":         "Compacter la conversation (résumé) pour libérer du contexte",
        "context":         "Afficher l'utilisation du contexte de la session",
        "init":            "Créer ou mettre à jour le CLAUDE.md du projet",
        "review":          "Passer en revue une pull request GitHub",
        "security-review": "Revue de sécurité des changements en cours",
        "code-review":     "Revue du diff courant (bugs et simplifications)",
        "simplify":        "Simplifier le code modifié (réutilisation, efficacité)",
        "verify":          "Vérifier un changement de bout en bout",
        "debug":           "Diagnostiquer un problème dans le projet",
        "usage":           "Afficher l'utilisation et les limites du compte",
        "model":           "Changer de modèle pour la session",
        "effort":          "Régler l'effort de raisonnement",
        "agents":          "Gérer les agents en arrière-plan",
        "mcp":             "Gérer les serveurs MCP",
        "recap":           "Résumé des dernières sessions",
        "insights":        "Statistiques d'utilisation détaillées",
        "goal":            "Fixer un objectif pour la session",
        "loop":            "Répéter un prompt ou une commande à intervalle",
        "schedule":        "Planifier un agent récurrent dans le cloud",
        "run":             "Lancer l'application du projet",
        "batch":           "Exécuter une tâche en lot",
        "doctor":          "Diagnostiquer l'installation de Claude Code",
        "dataviz":         "Guide de visualisation de données",
        "claude-api":      "Référence de l'API Claude / SDK Anthropic",
        "update-config":   "Configurer settings.json (permissions, hooks…)",
        "fewer-permission-prompts": "Réduire les demandes de permission",
    ]

    /// Fusionne les noms venant du CLI (init.slash_commands) avec les
    /// descriptions connues. Les noms internes (préfixe « _ ») sont écartés.
    /// ⚠️ Lit le disque (plugins, commandes perso) : à appeler hors du MainActor.
    static func commands(fromCLINames names: [String], projectDirectory: URL) -> [SlashCommand] {
        let descriptions = discoveredDescriptions(projectDirectory: projectDirectory)
        var seen = Set<String>()
        var commands: [SlashCommand] = []

        for name in names where !name.hasPrefix("_") && seen.insert(name).inserted {
            let description = builtinDescriptions[name]
                ?? descriptions[name]
                ?? defaultDescription(for: name)
            commands.append(SlashCommand(name: name, description: description))
        }

        // Repli : si le CLI n'a encore rien fourni (aucun message envoyé),
        // au moins les commandes documentées localement.
        if commands.isEmpty {
            for (name, description) in builtinDescriptions.sorted(by: { $0.key < $1.key })
            where !description.isEmpty {
                commands.append(SlashCommand(name: name, description: description))
            }
            for (name, description) in descriptions.sorted(by: { $0.key < $1.key })
            where seen.insert(name).inserted {
                commands.append(SlashCommand(name: name, description: description))
            }
        }

        return commands.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func defaultDescription(for name: String) -> String {
        name.contains(":") ? "Commande du plugin \(name.split(separator: ":")[0])"
                           : "Commande Claude Code"
    }

    // MARK: - Descriptions découvertes sur disque

    /// nom de commande → description, en scannant plugins, commandes et skills.
    static func discoveredDescriptions(projectDirectory: URL) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [String: String] = [:]

        // Commandes et skills perso : projet puis utilisateur (le projet prime).
        for base in [home, projectDirectory].map({ $0.appendingPathComponent(".claude", isDirectory: true) }) {
            merge(commandFiles(in: base.appendingPathComponent("commands"), prefix: nil), into: &result)
            merge(skillDirectories(in: base.appendingPathComponent("skills"), prefix: nil), into: &result)
        }

        // Plugins : ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/…
        // Le nom exposé par le CLI est « <plugin>:<commande> ».
        let pluginsCache = home.appendingPathComponent(".claude/plugins/cache", isDirectory: true)
        for marketplace in subdirectories(of: pluginsCache) {
            for plugin in subdirectories(of: marketplace) {
                let pluginName = plugin.lastPathComponent
                for version in subdirectories(of: plugin) {
                    merge(commandFiles(in: version.appendingPathComponent("commands"),
                                       prefix: pluginName), into: &result)
                    merge(skillDirectories(in: version.appendingPathComponent("skills"),
                                           prefix: pluginName), into: &result)
                }
            }
        }
        return result
    }

    private static func merge(_ new: [String: String], into result: inout [String: String]) {
        for (key, value) in new where result[key] == nil {
            result[key] = value
        }
    }

    private static func subdirectories(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
    }

    /// `<dossier>/commands/**.md` — un fichier = une commande. Les sous-dossiers
    /// forment un espace de noms : `git/commit.md` → « git:commit ».
    private static func commandFiles(in directory: URL, prefix: String?) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator
        where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
            let relative = url.deletingPathExtension().path
                .replacingOccurrences(of: directory.path + "/", with: "")
                .replacingOccurrences(of: "/", with: ":")
            guard !relative.isEmpty, let description = frontmatterDescription(of: url) else { continue }
            let name = prefix.map { "\($0):\(relative)" } ?? relative
            result[name] = description
        }
        return result
    }

    /// `<dossier>/skills/<nom>/SKILL.md` — un dossier = une skill.
    private static func skillDirectories(in directory: URL, prefix: String?) -> [String: String] {
        var result: [String: String] = [:]
        for entry in subdirectories(of: directory) {
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard let description = frontmatterDescription(of: manifest) else { continue }
            let name = prefix.map { "\($0):\(entry.lastPathComponent)" } ?? entry.lastPathComponent
            result[name] = description
        }
        return result
    }

    // MARK: - Frontmatter

    /// Extrait `description:` du frontmatter YAML (premières lignes du fichier).
    /// Lecture partielle : 4 Ko suffisent, même pour un gros SKILL.md.
    static func frontmatterDescription(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return frontmatterDescription(in: text)
    }

    static func frontmatterDescription(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break } // fin du frontmatter
            guard trimmed.lowercased().hasPrefix("description:") else { continue }
            var value = trimmed.dropFirst("description:".count)
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if value.count > 120 { value = String(value.prefix(120)) + "…" }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

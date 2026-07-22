import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Skill — une « compétence » Claude Code
//
// Un skill est un DOSSIER contenant un SKILL.md (frontmatter YAML + instructions
// Markdown), éventuellement accompagné de scripts et ressources. Claude Code les
// découvre tout seul dans :
//   • ~/.claude/skills/<nom>/            (global, tous projets)
//   • <projet>/.claude/skills/<nom>/     (propre au projet)
//   • les plugins installés               (lecture seule)
//
// L'app ne fait que POSER ou RETIRER ces dossiers ; c'est le CLI qui charge les
// skills au lancement suivant. Rien à piloter, aucun risque d'exécution ici.
// ─────────────────────────────────────────────────────────────────────────────

struct Skill: Identifiable, Equatable, Hashable, Sendable {
    /// Slug = nom du dossier. Sert d'identité : un même skill installé ET présent
    /// au catalogue est fusionné en une seule entrée (dédup par nom).
    let name: String
    let description: String
    let origin: Origin
    /// Non-nil si le skill est présent localement — porte le périmètre.
    var installed: InstalledScope?
    /// Étoiles du dépôt d'origine (skills communautaires) — signal de qualité,
    /// affiché et utilisé pour trier. nil = inconnu ou hors GitHub.
    var stars: Int?

    /// Provenance connue, pour le badge de confiance de l'UI.
    enum Origin: Equatable, Hashable, Sendable {
        case official                     // anthropics/skills — curé
        case community(CommunitySource)   // recherche GitHub (phase 2) — NON vérifié
        case local                        // installé, absent des catalogues connus
    }

    /// De QUOI installer un skill trouvé sur GitHub : un dépôt quelconque, une
    /// révision, et le dossier où vit le SKILL.md (racine possible). Le nom
    /// d'installation, lui, vient du frontmatter, pas du dossier du dépôt.
    struct CommunitySource: Equatable, Hashable, Sendable {
        let repo: String        // "owner/name"
        let ref: String         // branche ou SHA de commit
        let folderPath: String  // dossier du skill dans le dépôt ; "" = racine
    }

    /// Où un skill installé réside — décide s'il est désinstallable (pas les
    /// plugins, gérés par leur marketplace) et ce qu'affiche l'UI.
    enum InstalledScope: String, Sendable, Hashable, CaseIterable {
        case user      // ~/.claude/skills
        case project   // <projet>/.claude/skills
        case plugin    // fourni par un plugin — lecture seule

        var label: String {
            switch self {
            case .user:    return "Global"
            case .project: return "Projet"
            case .plugin:  return "Plugin"
            }
        }
    }

    var id: String { name }
    var isInstalled: Bool { installed != nil }
    /// Seuls les skills posés par l'utilisateur se retirent ; un skill de plugin
    /// appartient à son plugin.
    var isRemovable: Bool { installed == .user || installed == .project }
}

// MARK: - Frontmatter

/// Lecture du frontmatter YAML en tête d'un SKILL.md. On ne dépend d'aucune
/// bibliothèque YAML : le frontmatter des skills est plat (name, description,
/// parfois license), un parseur ciblé suffit et évite une dépendance.
enum SkillFrontmatter {

    /// Extrait au minimum `name` et `description`. Renvoie nil si le bloc
    /// `---` … `---` est absent ou sans nom — un skill sans nom est inexploitable.
    static func parse(_ content: String) -> (name: String, description: String)? {
        guard let fields = fields(in: content),
              let name = fields["name"], !name.isEmpty else { return nil }
        return (name, fields["description"] ?? "")
    }

    /// Paires clé/valeur du bloc frontmatter. Gère les valeurs entre guillemets,
    /// le style bloc `>-`/`|` sur une ligne, et ignore les lignes de continuation.
    static func fields(in content: String) -> [String: String]? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        // Le frontmatter DOIT ouvrir le fichier (après un éventuel BOM/espaces).
        let trimmed = normalized.drop { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " }
        guard trimmed.hasPrefix("---\n") else { return nil }

        let afterOpen = trimmed.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---") else { return nil }
        let block = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]

        var fields: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            // Une clé YAML de haut niveau ne commence pas par une espace : les
            // lignes indentées (continuation d'un bloc) sont ignorées, sans quoi
            // une description multi-lignes polluerait les clés.
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            value = stripQuotes(value)
            // Marqueurs de bloc YAML (« >- », « | ») sans contenu sur la ligne :
            // rien d'exploitable simplement, on garde une valeur vide.
            if value == ">" || value == ">-" || value == "|" || value == "|-" { value = "" }
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!, last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

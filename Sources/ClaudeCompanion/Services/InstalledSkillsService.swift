import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// InstalledSkillsService — les skills DÉJÀ présents sur la machine
//
// Scanne les trois emplacements que Claude Code lit au lancement :
//   • ~/.claude/skills/<nom>/SKILL.md            → périmètre .user (global)
//   • <projet>/.claude/skills/<nom>/SKILL.md     → périmètre .project
//   • ~/.claude/plugins/cache/**/skills/<nom>/   → périmètre .plugin (lecture seule)
//
// 100 % local, aucune permission, aucun réseau : c'est la source « Installés »,
// disponible même hors ligne et avant tout accès GitHub.
// ─────────────────────────────────────────────────────────────────────────────

enum InstalledSkillsService {

    /// Répertoire ~/.claude (les sessions y sont déjà, cf. SessionHistoryService).
    static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func userSkillsDirectory() -> URL {
        claudeHome.appendingPathComponent("skills")
    }

    static func projectSkillsDirectory(for projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent(".claude/skills")
    }

    /// Tous les skills installés, dédupliqués par nom. En cas de doublon, le
    /// périmètre le plus SPÉCIFIQUE gagne (projet > global > plugin) : c'est
    /// aussi la priorité qu'applique le CLI quand deux skills se nomment pareil.
    static func installedSkills(projectDirectory: URL) -> [Skill] {
        var byName: [String: Skill] = [:]

        // Ordre d'insertion = ordre de priorité CROISSANT : on écrase donc en
        // remontant vers le plus spécifique.
        let sources: [(URL, Skill.InstalledScope)] = [
            (userSkillsDirectory(), .user),
            (projectSkillsDirectory(for: projectDirectory), .project),
        ]
        for skill in pluginSkills() {
            byName[skill.name] = skill
        }
        for (directory, scope) in sources {
            for skill in scan(directory, scope: scope) {
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Skills fournis par les plugins installés. Deux dispositions coexistent
    /// dans la nature (« .claude/skills » et « skills » à la racine du plugin) —
    /// on couvre les deux.
    static func pluginSkills() -> [Skill] {
        let cache = claudeHome.appendingPathComponent("plugins/cache")
        let fm = FileManager.default
        guard let markets = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [Skill] = []
        for market in markets {
            // cache/<marché>/<plugin>/<version>/{.claude/skills, skills}/
            let plugins = (try? fm.contentsOfDirectory(at: market, includingPropertiesForKeys: nil)) ?? []
            for plugin in plugins {
                let versions = (try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: nil)) ?? []
                for version in versions {
                    for sub in [".claude/skills", "skills"] {
                        let dir = version.appendingPathComponent(sub)
                        result.append(contentsOf: scan(dir, scope: .plugin))
                    }
                }
            }
        }
        return result
    }

    /// Lit chaque sous-dossier `<dir>/<nom>/SKILL.md` et en extrait un Skill.
    /// Un dossier sans SKILL.md valide est simplement ignoré.
    static func scan(_ directory: URL, scope: Skill.InstalledScope) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries.compactMap { entry in
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: manifest, encoding: .utf8),
                  let meta = SkillFrontmatter.parse(content) else { return nil }
            return Skill(name: meta.name, description: meta.description,
                         origin: .local, installed: scope)
        }
    }
}

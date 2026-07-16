import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillInstaller — poser / retirer un skill
//
// Un skill est un DOSSIER : l'installer, c'est récupérer TOUS ses fichiers
// (SKILL.md, scripts, ressources), pas seulement le manifeste. On liste l'arbre
// du dépôt une fois, puis on télécharge chaque fichier via raw (hors quota) en
// préservant l'arborescence interne du skill.
//
// Sécurité : un skill peut embarquer des scripts que Claude exécutera. On expose
// donc `scriptFiles` pour que l'UI prévienne AVANT d'installer, et l'installation
// reste un geste explicite, par skill, avec choix du périmètre.
// ─────────────────────────────────────────────────────────────────────────────

enum SkillInstaller {

    enum InstallError: LocalizedError {
        case notInstallable
        case listingFailed
        case downloadFailed(String)
        case alreadyExists(String)
        case notRemovable

        var errorDescription: String? {
            switch self {
            case .notInstallable:      return "Ce skill n'est pas installable depuis le catalogue."
            case .listingFailed:       return "Impossible de lister les fichiers du skill (GitHub injoignable ?)."
            case .downloadFailed(let f): return "Échec du téléchargement de « \(f) »."
            case .alreadyExists(let n): return "Un skill « \(n) » existe déjà à cet emplacement."
            case .notRemovable:        return "Ce skill est fourni par un plugin : gérez-le via son plugin."
            }
        }
    }

    /// Un fichier du skill, chemin relatif au dossier du skill.
    struct SkillFile: Equatable {
        let relativePath: String   // "SKILL.md", "scripts/run.py"…
        var isScript: Bool { Self.scriptExtensions.contains((relativePath as NSString).pathExtension.lowercased()) }
        static let scriptExtensions: Set<String> = ["sh", "py", "js", "rb", "pl", "bash", "zsh", "command"]
    }

    // MARK: - Emplacements

    static func destinationRoot(scope: Skill.InstalledScope, projectDirectory: URL) -> URL {
        switch scope {
        case .project: return InstalledSkillsService.projectSkillsDirectory(for: projectDirectory)
        default:       return InstalledSkillsService.userSkillsDirectory()
        }
    }

    // MARK: - Aperçu (panneau de revue avant install)

    /// Le SKILL.md brut d'un skill officiel — pour l'afficher avant d'installer.
    static func officialManifest(named name: String) async -> String? {
        let url = GitHubFetch.rawURL(repo: SkillCatalogService.repo, path: "skills/\(name)/SKILL.md")
        guard let data = await GitHubFetch.get(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Liste des fichiers d'un skill officiel, pour repérer les scripts avant
    /// installation. Renvoie nil si l'arbre est injoignable.
    static func officialFiles(named name: String) async -> [SkillFile]? {
        guard let paths = await officialBlobPaths(named: name) else { return nil }
        let prefix = "skills/\(name)/"
        return paths.map { SkillFile(relativePath: String($0.dropFirst(prefix.count))) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Installation

    static func install(_ skill: Skill,
                        scope: Skill.InstalledScope,
                        projectDirectory: URL) async throws {
        guard case .official = skill.origin else { throw InstallError.notInstallable }

        let root = destinationRoot(scope: scope, projectDirectory: projectDirectory)
        let destination = root.appendingPathComponent(skill.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw InstallError.alreadyExists(skill.name)
        }

        guard let paths = await officialBlobPaths(named: skill.name), !paths.isEmpty else {
            throw InstallError.listingFailed
        }

        // On télécharge dans un dossier temporaire puis on déplace d'un bloc :
        // une install interrompue ne laisse jamais un skill à moitié écrit que
        // le CLI tenterait de charger.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-\(skill.name)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let prefix = "skills/\(skill.name)/"
        for path in paths {
            let relative = String(path.dropFirst(prefix.count))
            guard let data = await GitHubFetch.get(
                GitHubFetch.rawURL(repo: SkillCatalogService.repo, path: path)
            ) else { throw InstallError.downloadFailed(relative) }

            let fileURL = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    // MARK: - Désinstallation

    static func uninstall(_ skill: Skill, projectDirectory: URL) throws {
        guard skill.isRemovable, let scope = skill.installed else {
            throw InstallError.notRemovable
        }
        let dir = destinationRoot(scope: scope, projectDirectory: projectDirectory)
            .appendingPathComponent(skill.name)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Arbre du dépôt

    /// Chemins des fichiers (blobs) sous `skills/<name>/` dans anthropics/skills.
    private static func officialBlobPaths(named name: String) async -> [String]? {
        let url = URL(string:
            "https://api.github.com/repos/\(SkillCatalogService.repo)/git/trees/main?recursive=1")!
        guard let data = await GitHubFetch.get(url) else { return nil }

        struct Tree: Decodable {
            struct Node: Decodable { let path: String; let type: String }
            let tree: [Node]
        }
        guard let tree = try? JSONDecoder().decode(Tree.self, from: data) else { return nil }
        let prefix = "skills/\(name)/"
        return tree.tree
            .filter { $0.type == "blob" && $0.path.hasPrefix(prefix) }
            .map(\.path)
    }
}

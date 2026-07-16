import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillInstaller — poser / retirer un skill (officiel OU communautaire)
//
// Un skill est un DOSSIER : l'installer récupère TOUS ses fichiers (SKILL.md,
// scripts, ressources), pas seulement le manifeste. On liste l'arbre du dépôt,
// on filtre le sous-dossier du skill, puis on télécharge chaque fichier via raw
// (à la révision exacte prévisualisée). Staging temporaire + déplacement
// atomique : une install interrompue ne laisse jamais un skill à moitié écrit.
//
// Sécurité : `officialFiles`/`files(for:)` exposent les scripts embarqués pour
// que l'UI prévienne AVANT d'installer. Les skills communautaires sont NON
// vérifiés — l'aperçu et l'alerte scripts sont le garde-fou.
//
// Garde-fou taille : un SKILL.md à la RACINE d'un dépôt ferait du dossier tout
// le dépôt. On borne à `maxFiles` et on refuse au-delà (install manuelle alors).
// ─────────────────────────────────────────────────────────────────────────────

enum SkillInstaller {

    static let maxFiles = 100

    enum InstallError: LocalizedError {
        case notInstallable
        case listingFailed
        case tooManyFiles
        case downloadFailed(String)
        case alreadyExists(String)
        case notRemovable

        var errorDescription: String? {
            switch self {
            case .notInstallable:       return "Ce skill n'est pas installable automatiquement."
            case .listingFailed:        return "Impossible de lister les fichiers du skill (dépôt injoignable ?)."
            case .tooManyFiles:         return "Ce dépôt contient trop de fichiers pour une install sûre — clonez-le à la main."
            case .downloadFailed(let f): return "Échec du téléchargement de « \(f) »."
            case .alreadyExists(let n): return "Un skill « \(n) » existe déjà à cet emplacement."
            case .notRemovable:         return "Ce skill est fourni par un plugin : gérez-le via son plugin."
            }
        }
    }

    /// Un fichier du skill, chemin relatif au dossier du skill.
    struct SkillFile: Equatable {
        let relativePath: String   // "SKILL.md", "scripts/run.py"…
        var isScript: Bool { Self.scriptExtensions.contains((relativePath as NSString).pathExtension.lowercased()) }
        static let scriptExtensions: Set<String> = ["sh", "py", "js", "rb", "pl", "bash", "zsh", "command"]
    }

    /// Où récupérer un skill distant : dépôt, révision, dossier (racine = "").
    private struct Remote {
        let repo: String
        let ref: String
        let folderPath: String
        /// Préfixe à retirer des chemins de l'arbre pour obtenir le relatif.
        var prefix: String { folderPath.isEmpty ? "" : folderPath + "/" }
    }

    private static func remote(for skill: Skill) -> Remote? {
        switch skill.origin {
        case .official:
            return Remote(repo: SkillCatalogService.repo, ref: "main", folderPath: "skills/\(skill.name)")
        case .community(let source):
            return Remote(repo: source.repo, ref: source.ref, folderPath: source.folderPath)
        case .local:
            return nil
        }
    }

    // MARK: - Emplacements

    static func destinationRoot(scope: Skill.InstalledScope, projectDirectory: URL) -> URL {
        switch scope {
        case .project: return InstalledSkillsService.projectSkillsDirectory(for: projectDirectory)
        default:       return InstalledSkillsService.userSkillsDirectory()
        }
    }

    // MARK: - Aperçu (panneau de revue avant install)

    /// Le SKILL.md brut d'un skill distant, pour l'afficher avant d'installer.
    static func manifest(for skill: Skill) async -> String? {
        guard let remote = remote(for: skill) else { return nil }
        let path = remote.folderPath.isEmpty ? "SKILL.md" : remote.folderPath + "/SKILL.md"
        guard let data = await GitHubFetch.get(
            GitHubFetch.rawURL(repo: remote.repo, branch: remote.ref, path: path)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fichiers du skill distant, pour repérer les scripts. nil si injoignable.
    static func files(for skill: Skill) async -> [SkillFile]? {
        guard let remote = remote(for: skill),
              let paths = await blobPaths(remote) else { return nil }
        return paths.map { SkillFile(relativePath: String($0.dropFirst(remote.prefix.count))) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Installation

    static func install(_ skill: Skill,
                        scope: Skill.InstalledScope,
                        projectDirectory: URL) async throws {
        guard let remote = remote(for: skill) else { throw InstallError.notInstallable }

        let root = destinationRoot(scope: scope, projectDirectory: projectDirectory)
        let destination = root.appendingPathComponent(skill.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw InstallError.alreadyExists(skill.name)
        }

        guard let paths = await blobPaths(remote), !paths.isEmpty else {
            throw InstallError.listingFailed
        }
        guard paths.count <= maxFiles else { throw InstallError.tooManyFiles }

        // Staging puis move atomique : jamais de skill à moitié écrit sur disque.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-\(skill.name)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let token = GitHubAuth.token() // relève les quotas raw sur dépôts privés
        for path in paths {
            let relative = String(path.dropFirst(remote.prefix.count))
            guard !relative.isEmpty else { continue }
            guard let data = await GitHubFetch.get(
                GitHubFetch.rawURL(repo: remote.repo, branch: remote.ref, path: path), token: token
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

    /// Chemins des fichiers (blobs) du dossier du skill, à la révision voulue.
    private static func blobPaths(_ remote: Remote) async -> [String]? {
        let url = URL(string:
            "https://api.github.com/repos/\(remote.repo)/git/trees/\(remote.ref)?recursive=1")!
        guard let data = await GitHubFetch.get(url, token: GitHubAuth.token()) else { return nil }

        struct Tree: Decodable {
            struct Node: Decodable { let path: String; let type: String }
            let tree: [Node]
        }
        guard let tree = try? JSONDecoder().decode(Tree.self, from: data) else { return nil }
        let prefix = remote.prefix
        return tree.tree
            .filter { $0.type == "blob" && (prefix.isEmpty || $0.path.hasPrefix(prefix)) }
            .map(\.path)
    }
}

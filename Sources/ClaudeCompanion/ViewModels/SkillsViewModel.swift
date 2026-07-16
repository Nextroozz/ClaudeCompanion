import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SkillsViewModel — orchestre les trois sources de skills pour l'UI
//
// Installés (scan local), catalogue officiel (GitHub, caché) et suggestions
// (déterministes, selon le projet). Tout le réseau est poussé hors du MainActor
// via les services ; ce ViewModel ne fait que coordonner et publier l'état.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SkillsViewModel: ObservableObject {

    @Published private(set) var installed: [Skill] = []
    @Published private(set) var catalog: [Skill] = []          // officiel, drapeau installé posé
    @Published private(set) var suggestions: [SkillSuggestion] = []
    @Published private(set) var isRefreshing = false
    @Published var errorText: String?
    /// Nom du skill dont une install/désinstall est en cours (désactive son bouton).
    @Published var busySkill: String?

    private var projectDirectory = FileManager.default.homeDirectoryForCurrentUser

    /// Exposé pour l'aperçu d'un skill installé, lu sur disque par la vue détail.
    var projectDirectoryForPreview: URL { projectDirectory }

    func configure(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
    }

    /// Noms des skills installés — pour marquer le catalogue et filtrer les
    /// suggestions.
    var installedNames: Set<String> { Set(installed.map(\.name)) }

    // MARK: - Chargement

    /// Affiche immédiatement le local + le cache, puis rafraîchit le catalogue
    /// en tâche de fond. L'UI n'attend jamais le réseau pour s'ouvrir.
    func load() async {
        rescanLocal()
        catalog = merge(SkillCatalogService.cachedCatalog())
        recomputeSuggestions()

        isRefreshing = true
        let fresh = await SkillCatalogService.refreshedCatalog()
        isRefreshing = false
        if !fresh.isEmpty {
            catalog = merge(fresh)
            recomputeSuggestions()
        }
    }

    private func rescanLocal() {
        installed = InstalledSkillsService.installedSkills(projectDirectory: projectDirectory)
    }

    /// Pose le drapeau « installé » (et son périmètre) sur les entrées du
    /// catalogue déjà présentes localement : un même nom = un même skill.
    private func merge(_ catalog: [Skill]) -> [Skill] {
        let byName = Dictionary(installed.map { ($0.name, $0.installed) }, uniquingKeysWith: { a, _ in a })
        return catalog.map { skill in
            var copy = skill
            if let scope = byName[skill.name] { copy.installed = scope }
            return copy
        }
    }

    private func recomputeSuggestions() {
        let signals = SkillSuggester.detectSignals(in: projectDirectory)
        suggestions = SkillSuggester.suggestions(for: signals, catalog: catalog,
                                                 installed: installedNames)
    }

    // MARK: - Actions

    func install(_ skill: Skill, scope: Skill.InstalledScope) async {
        errorText = nil
        busySkill = skill.name
        do {
            try await SkillInstaller.install(skill, scope: scope, projectDirectory: projectDirectory)
            rescanLocal()
            catalog = merge(catalog)
            recomputeSuggestions()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busySkill = nil
    }

    func uninstall(_ skill: Skill) async {
        errorText = nil
        busySkill = skill.name
        do {
            try SkillInstaller.uninstall(skill, projectDirectory: projectDirectory)
            rescanLocal()
            catalog = merge(catalog)
            recomputeSuggestions()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busySkill = nil
    }
}

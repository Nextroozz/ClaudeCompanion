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
    /// Suggestions issues de GitHub (recherche selon le projet), triées par
    /// étoiles. Séparées des officielles : provenance non vérifiée.
    @Published private(set) var communitySuggestions: [SkillSuggestion] = []
    @Published private(set) var isRefreshing = false
    @Published var errorText: String?
    /// Nom du skill dont une install/désinstall est en cours (désactive son bouton).
    @Published var busySkill: String?

    // Recherche GitHub (Phase 2).
    @Published private(set) var searchResults: [Skill] = []
    @Published private(set) var isSearching = false
    /// `gh` présent et connecté ? Sinon la recherche large est indisponible.
    @Published private(set) var searchAvailable = false

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

        // Disponibilité de la recherche GitHub (localise `gh` hors MainActor).
        searchAvailable = await Task.detached { GitHubAuth.isAvailable }.value

        await refreshCommunitySuggestions()
    }

    /// Cherche sur GitHub des skills adaptés au projet (signal le plus fort) et
    /// garde les 3 mieux notés, hors déjà installés. Silencieux si `gh` manque.
    private func refreshCommunitySuggestions() async {
        guard searchAvailable else { return }
        let signals = SkillSuggester.detectSignals(in: projectDirectory)
        guard let ask = SkillSuggester.communityQuery(for: signals),
              let results = try? await SkillSearchService.search(ask.query) else { return }

        communitySuggestions = results
            .filter { !installedNames.contains($0.name) }
            .prefix(3)
            .map { SkillSuggestion(skill: $0, reason: ask.reason) }
    }

    // MARK: - Recherche GitHub (Phase 2)

    func search(_ query: String) async {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { searchResults = []; return }
        errorText = nil
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await SkillSearchService.search(terms)
            // On marque les résultats déjà installés (dédup par nom).
            searchResults = results.map { skill in
                var copy = skill
                if let scope = installed.first(where: { $0.name == skill.name })?.installed {
                    copy.installed = scope
                }
                return copy
            }
        } catch {
            searchResults = []
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearSearch() { searchResults = [] }

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

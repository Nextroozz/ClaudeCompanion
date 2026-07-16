import SwiftUI

/// Panneau de gestion des skills : Installés · Suggérés · Découvrir. On y
/// parcourt les skills du projet et du catalogue officiel, on en ouvre le détail
/// (aperçu du SKILL.md + alerte scripts) et on installe/désinstalle.
struct SkillsView: View {
    let projectDirectory: URL
    @StateObject private var model = SkillsViewModel()
    @State private var tab: Tab = .installed
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installés"
        case suggested = "Suggérés"
        case discover  = "Découvrir"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                picker
                Divider()
                content
            }
            .navigationTitle("Skills")
            .navigationDestination(for: Skill.self) { skill in
                SkillDetailView(skill: skill, model: model)
            }
            .toolbar {
                // Une sheet macOS n'offre aucune fermeture par défaut : sans ce
                // bouton (et Échap), le panneau était piégé ouvert.
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction) // Échap ferme aussi
                    .help("Fermer (Échap)")
                }
            }
        }
        .frame(width: 460, height: 560)
        .task { model.configure(projectDirectory: projectDirectory); await model.load() }
        .overlay(alignment: .bottom) { errorBar }
    }

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { t in
                if t == .suggested, !model.suggestions.isEmpty {
                    Text("\(t.rawValue) (\(model.suggestions.count))").tag(t)
                } else {
                    Text(t.rawValue).tag(t)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed: installedList
        case .suggested: suggestedList
        case .discover:  discoverList
        }
    }

    // MARK: - Installés

    private var installedList: some View {
        Group {
            if model.installed.isEmpty {
                emptyState("puzzlepiece.extension",
                           "Aucun skill installé",
                           "Ajoutez-en depuis « Découvrir » ou « Suggérés ».")
            } else {
                List(model.installed) { skill in
                    NavigationLink(value: skill) { SkillRow(skill: skill, model: model) }
                }
            }
        }
    }

    // MARK: - Suggérés

    private var suggestedList: some View {
        Group {
            if model.suggestions.isEmpty {
                emptyState("sparkles",
                           "Rien à suggérer pour l'instant",
                           "Les propositions se basent sur le contenu du projet ouvert.")
            } else {
                List(model.suggestions) { suggestion in
                    NavigationLink(value: suggestion.skill) {
                        SkillRow(skill: suggestion.skill, model: model, reason: suggestion.reason)
                    }
                }
            }
        }
    }

    // MARK: - Découvrir

    private var discoverList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrer l'officiel · ⏎ pour chercher sur GitHub", text: $search)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search(search) } }
                if !search.isEmpty {
                    Button {
                        search = ""; model.clearSearch()
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
                if model.isRefreshing || model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            List {
                Section("Catalogue officiel") {
                    if filteredCatalog.isEmpty {
                        Text(model.catalog.isEmpty
                             ? "Catalogue indisponible (GitHub injoignable ?)."
                             : "Aucun skill officiel ne correspond.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredCatalog) { skill in
                            NavigationLink(value: skill) { SkillRow(skill: skill, model: model) }
                        }
                    }
                }

                // Résultats GitHub : uniquement après une recherche explicite.
                if !model.searchResults.isEmpty {
                    Section {
                        ForEach(model.searchResults) { skill in
                            NavigationLink(value: skill) { SkillRow(skill: skill, model: model) }
                        }
                    } header: {
                        Label("GitHub — non vérifiés", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("Sources tierces : lisez le SKILL.md et vérifiez les scripts avant d'installer.")
                            .font(.caption2)
                    }
                } else if !search.isEmpty && !model.isSearching {
                    Section {
                        if model.searchAvailable {
                            Text("Appuyez sur ⏎ pour chercher « \(search) » sur GitHub.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Label("Recherche GitHub indisponible : installez « gh » puis « gh auth login ».",
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var filteredCatalog: [Skill] {
        guard !search.isEmpty else { return model.catalog }
        let q = search.lowercased()
        return model.catalog.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    // MARK: - Fragments

    private func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorBar: some View {
        if let error = model.errorText {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.errorText = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
    }
}

// MARK: - Ligne de skill

struct SkillRow: View {
    let skill: Skill
    @ObservedObject var model: SkillsViewModel
    var reason: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SkillBadge(skill: skill)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.callout.weight(.medium))
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(Color.accentColor)
                }
                Text(skill.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if skill.isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Installé (\(skill.installed?.label ?? ""))")
            }
        }
        .padding(.vertical, 3)
    }
}

/// Pastille de provenance : la confiance se lit d'un coup d'œil.
struct SkillBadge: View {
    let skill: Skill

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .help(helpText)
    }

    private var symbol: String {
        switch skill.origin {
        case .official:  return "checkmark.seal.fill"
        case .community: return "person.2"
        case .local:     return skill.installed == .plugin ? "puzzlepiece.fill" : "folder.fill"
        }
    }
    private var color: Color {
        switch skill.origin {
        case .official:  return .accentColor
        case .community: return .orange
        case .local:     return .secondary
        }
    }
    private var helpText: String {
        switch skill.origin {
        case .official:  return "Skill officiel (anthropics/skills)"
        case .community: return "Communauté — non vérifié"
        case .local:     return skill.installed == .plugin ? "Fourni par un plugin" : "Skill local"
        }
    }
}

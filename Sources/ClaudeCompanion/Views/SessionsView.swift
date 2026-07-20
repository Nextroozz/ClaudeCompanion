import SwiftUI

/// Panneau de gestion des sessions : renommer, colorer, grouper, supprimer.
/// Les sessions viennent de Claude Code (.jsonl) ; les décorations vivent à
/// part dans SessionMetadataStore. On les affiche regroupées, chaque groupe
/// trié par date décroissante.
struct SessionsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var meta: SessionMetadataStore
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: String?          // id en cours de renommage
    @State private var draftName = ""
    @State private var pendingDeletion: SessionSummary?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.sessions.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedSessions, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.sessions) { session in
                                    row(session)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Fermer (Échap)")
                }
            }
        }
        .frame(width: 460, height: 560)
        .alert("Supprimer cette session ?", isPresented: deletionBinding, presenting: pendingDeletion) { session in
            Button("Supprimer", role: .destructive) {
                meta.forget(session.id)
                viewModel.deleteSession(session)
            }
            Button("Annuler", role: .cancel) {}
        } message: { session in
            Text("« \(displayName(session)) » sera définitivement supprimée. Cette action est irréversible.")
        }
    }

    // MARK: - Ligne

    @ViewBuilder
    private func row(_ session: SessionSummary) -> some View {
        let m = meta.metadata(for: session.id)
        HStack(spacing: 10) {
            colorMenu(session, current: m.color)

            VStack(alignment: .leading, spacing: 2) {
                if renaming == session.id {
                    TextField("Nom", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(session) }
                } else {
                    Text(displayName(session))
                        .font(.callout.weight(session.id == viewModel.sessionID ? .semibold : .regular))
                        .lineLimit(1)
                }
                Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if session.id == viewModel.sessionID {
                Text("courante").font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            rowMenu(session, meta: m)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard renaming == nil else { return }
            viewModel.loadSession(session)
            dismiss()
        }
    }

    /// Pastille de couleur, cliquable → choix rapide.
    private func colorMenu(_ session: SessionSummary, current: SessionColor?) -> some View {
        Menu {
            Button("Aucune") { meta.setColor(nil, for: session.id) }
            ForEach(SessionColor.allCases) { c in
                Button {
                    meta.setColor(c, for: session.id)
                } label: {
                    Label(c.label, systemImage: current == c ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Circle()
                .fill(current?.color ?? Color.secondary.opacity(0.25))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: current == nil ? 1 : 0))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Menu « … » : renommer, grouper, supprimer.
    private func rowMenu(_ session: SessionSummary, meta m: SessionMetadata) -> some View {
        Menu {
            Button {
                draftName = m.name ?? session.title
                renaming = session.id
            } label: { Label("Renommer", systemImage: "pencil") }

            Menu {
                Button("Sans groupe") { meta.setGroup(nil, for: session.id) }
                if !meta.groups.isEmpty { Divider() }
                ForEach(meta.groups, id: \.self) { g in
                    Button {
                        meta.setGroup(g, for: session.id)
                    } label: {
                        Label(g, systemImage: m.group == g ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button {
                    draftName = ""
                    renaming = "group:" + session.id // réutilise le champ pour un nouveau groupe
                } label: { Label("Nouveau groupe…", systemImage: "folder.badge.plus") }
            } label: { Label("Groupe", systemImage: "folder") }

            Divider()
            Button(role: .destructive) {
                pendingDeletion = session
            } label: { Label("Supprimer", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Saisie d'un nouveau groupe : petit champ en overlay quand demandé.
        .popover(isPresented: newGroupBinding(session)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nouveau groupe").font(.caption.weight(.semibold))
                TextField("Nom du groupe", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit {
                        meta.setGroup(draftName, for: session.id)
                        renaming = nil
                    }
                HStack {
                    Spacer()
                    Button("Créer") {
                        meta.setGroup(draftName, for: session.id)
                        renaming = nil
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("Aucune session pour ce projet").font(.headline)
            Text("Envoyez un message pour démarrer une session.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Regroupement

    private struct SessionGroup { let name: String; let sessions: [SessionSummary] }

    /// Sessions regroupées par leur groupe (les sans-groupe en dernier), chaque
    /// groupe trié par date décroissante — l'ordre naturel de viewModel.sessions.
    private var groupedSessions: [SessionGroup] {
        var buckets: [String: [SessionSummary]] = [:]
        for session in viewModel.sessions {
            let key = meta.metadata(for: session.id).group ?? ungrouped
            buckets[key, default: []].append(session)
        }
        let named = buckets.keys.filter { $0 != ungrouped }.sorted()
        var result = named.map { SessionGroup(name: $0, sessions: buckets[$0] ?? []) }
        if let loose = buckets[ungrouped] {
            result.append(SessionGroup(name: ungrouped, sessions: loose))
        }
        return result
    }

    private let ungrouped = "Sans groupe"

    // MARK: - Helpers

    private func displayName(_ session: SessionSummary) -> String {
        let m = meta.metadata(for: session.id)
        return m.name ?? session.title
    }

    private func commitRename(_ session: SessionSummary) {
        meta.setName(draftName, for: session.id)
        renaming = nil
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    /// Le champ « nouveau groupe » se distingue du renommage par un préfixe.
    private func newGroupBinding(_ session: SessionSummary) -> Binding<Bool> {
        Binding(
            get: { renaming == "group:" + session.id },
            set: { if !$0 && renaming == "group:" + session.id { renaming = nil } }
        )
    }
}

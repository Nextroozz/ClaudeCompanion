import SwiftUI
import UniformTypeIdentifiers

/// Barre d'en-tête posée sur le verre : dossier de projet, badge modèle,
/// historique de sessions, permissions, épingle et ancrage IDE.
struct HeaderBarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var windowManager: WindowManager
    @State private var showsFolderPicker = false
    @State private var showsAccount = false
    @State private var showsWorkspace = false

    var body: some View {
        HStack(spacing: 8) {
            // Compte (en haut à gauche) : identité, connexion/déconnexion, usage.
            Button {
                showsAccount.toggle()
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Compte, connexion et usage")
            .popover(isPresented: $showsAccount, arrowEdge: .bottom) {
                AccountView()
                    .environmentObject(viewModel)
            }

            folderButton
            modelMenu

            Spacer(minLength: 8)

            sessionHistoryMenu

            Button {
                viewModel.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("Nouvelle session (⌘N)")

            permissionMenu

            Button {
                windowManager.isPinned.toggle()
            } label: {
                Image(systemName: windowManager.isPinned ? "pin.fill" : "pin.slash")
            }
            .buttonStyle(.plain)
            .help(windowManager.isPinned
                  ? "Épinglé : flotte au-dessus de l'IDE (cliquer pour détacher)"
                  : "Détaché : se comporte comme une fenêtre normale")

            dockMenu

            Button {
                showsWorkspace.toggle()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.plain)
            .foregroundStyle(windowManager.workspaceActive ? Color.accentColor : .primary.opacity(0.85))
            .help("Workspace : tuiler plusieurs apps et les maximiser ensemble")
            .popover(isPresented: $showsWorkspace, arrowEdge: .bottom) {
                WorkspaceView()
                    .environmentObject(windowManager)
            }
        }
        .imageScale(.medium)
        .foregroundStyle(.primary.opacity(0.85))
        // 78 pt à gauche : l'espace des feux rouge/jaune/vert, qui flottent
        // sur le contenu depuis que la barre de titre est transparente.
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                viewModel.setProjectDirectory(url)
            }
        }
    }

    private var folderButton: some View {
        Button {
            showsFolderPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(viewModel.projectDirectory.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Dossier de projet : \(viewModel.projectDirectory.path)")
    }

    /// Sélecteur de modèle et d'effort de raisonnement, appliqués dès le
    /// prochain message (`--model` / `--effort`). La liste des modèles vient
    /// de l'API Anthropic — les nouvelles versions apparaissent toutes seules.
    private var modelMenu: some View {
        Menu {
            Picker("Modèle", selection: $viewModel.selectedModel) {
                Text("Défaut").tag(String?.none)
                ForEach(viewModel.availableModels) { model in
                    Text(model.displayName).tag(String?.some(model.id))
                }
            }
            .pickerStyle(.inline)

            Picker("Effort de raisonnement", selection: $viewModel.selectedEffort) {
                ForEach(EffortChoice.all, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(modelBadgeText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let effortLabel = EffortChoice.label(for: viewModel.selectedEffort),
                   viewModel.selectedEffort != nil {
                    Text(effortLabel.lowercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Modèle et effort de raisonnement pour les prochains messages")
    }

    /// Nom affiché : le choix explicite s'il existe, sinon le modèle réellement
    /// utilisé par la session, sinon « Auto ».
    private var modelBadgeText: String {
        if let selected = viewModel.selectedModel {
            return viewModel.availableModels.first { $0.id == selected }?.displayName
                ?? ModelNames.short(selected)
        }
        if let model = viewModel.modelName {
            return ModelNames.short(model)
        }
        return "Auto"
    }

    private var sessionHistoryMenu: some View {
        Menu {
            if viewModel.sessions.isEmpty {
                Text("Aucune session pour ce projet")
            }
            ForEach(viewModel.sessions) { session in
                Button {
                    viewModel.loadSession(session)
                } label: {
                    Text(session.title)
                    Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reprendre une session précédente (historique ~/.claude/projects)")
    }

    private var permissionMenu: some View {
        Menu {
            Picker("Permissions des outils", selection: $viewModel.permissionMode) {
                ForEach(PermissionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: viewModel.permissionMode == .bypassPermissions
                  ? "shield.slash" : "shield")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mode de permission des outils en exécution headless")
    }

    // MARK: - Ancrage IDE

    /// Menu d'ancrage. La liste vient de `windowManager.dockableApps`, publiée
    /// et recalculée sur événement : un calcul fait ici serait figé au moment
    /// où SwiftUI construit le menu, et un IDE lancé après ne s'afficherait pas.
    private var dockMenu: some View {
        Menu {
            if let docked = windowManager.dockedApp {
                Section("Ancré à \(docked.localizedName ?? "?")") {
                    Button("Maximiser la paire") { windowManager.maximizePair() }
                    Button("Détacher") { windowManager.undock() }
                }
            }

            Picker("Côté", selection: Binding(
                get: { windowManager.dockSide },
                set: { windowManager.dockSide = $0 }
            )) {
                ForEach(DockSide.allCases, id: \.self) { side in
                    Text(side.label).tag(side)
                }
            }
            .pickerStyle(.inline)

            Section("Ancrer à…") {
                if windowManager.dockableApps.isEmpty {
                    Text("Aucune app avec fenêtre")
                } else {
                    ForEach(windowManager.dockableApps, id: \.processIdentifier) { app in
                        Button {
                            windowManager.dock(to: app)
                        } label: {
                            // L'icône est indispensable : VSCode s'annonce
                            // « Code » (son localizedName), nom sous lequel on
                            // ne le reconnaît pas. L'icône lève l'ambiguïté.
                            if let icon = app.icon {
                                Image(nsImage: icon)
                            }
                            Text(app.localizedName ?? "?")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: windowManager.isDocked
                  ? "rectangle.lefthalf.inset.filled.arrow.left"
                  : "rectangle.righthalf.inset.filled.arrow.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(windowManager.isDocked ? Color.accentColor : .primary.opacity(0.85))
        .help(windowManager.isDocked
              ? "Ancré à \(windowManager.dockedApp?.localizedName ?? "?") — les deux fenêtres bougent ensemble"
              : "Ancrer à un IDE : l'IDE rétrécit, le compagnon s'y colle (⌘⇧D)")
    }
}

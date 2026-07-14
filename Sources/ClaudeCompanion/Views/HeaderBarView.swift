import SwiftUI
import UniformTypeIdentifiers

/// Barre d'en-tête posée sur le verre : dossier de projet, badge modèle,
/// historique de sessions, permissions, épingle et ancrage IDE.
struct HeaderBarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var windowManager: WindowManager
    @State private var showsFolderPicker = false
    @State private var showsUsage = false

    var body: some View {
        HStack(spacing: 8) {
            folderButton
            if let model = viewModel.modelName {
                Text(ModelNames.short(model))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .help("Modèle de la session en cours")
            }

            Spacer(minLength: 8)

            Button {
                showsUsage.toggle()
            } label: {
                Image(systemName: "chart.bar.fill")
            }
            .buttonStyle(.plain)
            .help("Usage et coûts estimés (journaux locaux)")
            .popover(isPresented: $showsUsage, arrowEdge: .bottom) {
                UsageView()
                    .environmentObject(viewModel)
            }

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

            Button {
                NotificationCenter.default.post(name: .dockToIDERequested, object: nil)
            } label: {
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Ancrer à droite de \(windowManager.dockTargetAppName) (⌘⇧D)")
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

}

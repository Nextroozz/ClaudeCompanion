import AppKit
import SwiftUI

/// Panneau de composition du workspace : on y assemble les apps à tuiler
/// (Claude compris), on choisit l'axe, puis « Maximiser » les dispose sur tout
/// l'écran utile — l'équivalent le plus proche d'un plein écran à plusieurs
/// apps que macOS autorise (voir WorkspaceLayout pour le pourquoi).
struct WorkspaceView: View {
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            axisPicker
            Divider().opacity(0.4)
            tileList
            addMenu
            Divider().opacity(0.4)
            actions
            if let error = windowManager.dockError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(Color.accentColor)
            Text("Workspace")
                .font(.headline)
            Spacer()
            if windowManager.workspaceActive {
                Text("actif")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
        }
    }

    private var axisPicker: some View {
        Picker("Disposition", selection: Binding(
            get: { windowManager.workspace.axis },
            set: { windowManager.setWorkspaceAxis($0) }
        )) {
            Label("Côte à côte", systemImage: "rectangle.split.3x1").tag(Workspace.Axis.horizontal)
            Label("Empilées", systemImage: "rectangle.split.1x2").tag(Workspace.Axis.vertical)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var tileList: some View {
        VStack(spacing: 6) {
            ForEach(windowManager.workspace.tiles) { tile in
                tileRow(tile)
            }
        }
    }

    private func tileRow(_ tile: WorkspaceTile) -> some View {
        HStack(spacing: 9) {
            icon(for: tile)
            Text(name(for: tile))
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            if tile.isCompanion {
                // Claude ne se retire pas : un workspace sans lui n'aurait pas
                // de sens dans cette app.
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    windowManager.removeFromWorkspace(bundleID: tile.bundleID)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Apps ancrables pas encore dans le workspace.
    private var candidates: [NSRunningApplication] {
        let present = Set(windowManager.workspace.tiles.map(\.bundleID))
        return windowManager.dockableApps.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return !present.contains(id)
        }
    }

    private var addMenu: some View {
        Menu {
            if candidates.isEmpty {
                Text("Aucune autre app avec fenêtre")
            } else {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? "?") { windowManager.addToWorkspace(app) }
                }
            }
        } label: {
            Label("Ajouter une app", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            windowManager.applyWorkspace()
        } label: {
            Label("Maximiser le workspace", systemImage: "arrow.up.left.and.arrow.down.right")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(windowManager.workspace.tiles.count < 2)

        if windowManager.workspaceActive {
            Button("Quitter le workspace") { windowManager.exitWorkspace() }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
        }

        // Un seul écran ne loge que 3 tuiles de 380 pt : on prévient plutôt que
        // de laisser « Maximiser » échouer avec un message d'erreur.
        if windowManager.workspace.tiles.count >= 4 {
            Text("Astuce : au-delà de 3 apps côte à côte, un écran externe est nécessaire.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Nom & icône d'une tuile

    private func name(for tile: WorkspaceTile) -> String {
        if tile.isCompanion { return "Claude Companion" }
        return windowManager.runningApp(for: tile)?.localizedName ?? tile.bundleID
    }

    @ViewBuilder
    private func icon(for tile: WorkspaceTile) -> some View {
        if tile.isCompanion {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
        } else if let nsImage = windowManager.runningApp(for: tile)?.icon {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            // App fermée depuis son ajout : marqueur discret plutôt qu'un vide.
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
    }
}

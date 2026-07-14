import SwiftUI

/// Vue racine : verre profond derrière toute la fenêtre, en-tête, fil de
/// conversation auto-défilant, barre de saisie, bannière d'erreur.
struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 0) {
            HeaderBarView()
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            messageList
            InputBarView()
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480, idealHeight: 700)
        // ── L'effet « Liquid Glass » de fond : NSVisualEffectView en
        // .behindWindow. La fenêtre étant transparente (WindowManager), le
        // bureau et l'IDE transparaissent, floutés, sous toute l'app.
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, isEmphasized: true)
                .ignoresSafeArea()
        }
        .background(WindowConfigurator { windowManager.adopt($0) })
        .overlay(alignment: .top) { errorBanner }
        .animation(.spring(duration: 0.3), value: viewModel.errorText)
        .onReceive(NotificationCenter.default.publisher(for: .newSessionRequested)) { _ in
            viewModel.newSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockToIDERequested)) { _ in
            dockToIDE()
        }
    }

    // MARK: - Fil de conversation

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message)
                    }
                    // Ancre invisible pour l'auto-défilement.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: viewModel.revision) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(
                    LinearGradient(colors: [.accentColor, .purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("Claude Companion")
                .font(.title3.weight(.semibold))
            Text("Panneau compagnon pour CodeEdit.\nChoisissez un dossier de projet (en haut à gauche), puis posez votre question.\n⏎ envoyer · ⌥⏎ nouvelle ligne · ⌘N nouvelle session")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - Erreurs

    @ViewBuilder
    private var errorBanner: some View {
        if let errorText = viewModel.errorText {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(errorText)
                    .font(.callout)
                    .lineLimit(5)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    viewModel.errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14), tint: .red)
            .padding(.horizontal, 16)
            .padding(.top, 46) // sous la barre de titre fantôme
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func dockToIDE() {
        if !windowManager.dockToCodeEdit() {
            viewModel.errorText = "Fenêtre « \(windowManager.dockTargetAppName) » introuvable à l'écran. Ouvrez l'IDE puis réessayez (⌘⇧D)."
        }
    }
}

extension Notification.Name {
    static let newSessionRequested = Notification.Name("ClaudeCompanion.newSession")
    static let dockToIDERequested = Notification.Name("ClaudeCompanion.dockToIDE")
}

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
            if let activity = viewModel.currentActivity {
                ActivityIndicatorView(activity: activity,
                                      detail: viewModel.activityDetail,
                                      startedAt: viewModel.turnStartedAt,
                                      showsGame: viewModel.isWaiting)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            InputBarView()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.currentActivity)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480, idealHeight: 700)
        // ── L'effet « Liquid Glass » de fond : NSVisualEffectView en
        // .behindWindow. La fenêtre étant transparente (WindowManager), le
        // bureau et l'IDE transparaissent, floutés, sous toute l'app.
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, isEmphasized: true)
                .ignoresSafeArea()
        }
        .background(WindowConfigurator { windowManager.adopt($0) })
        // Glisser-déposer de fichiers depuis le Finder → pièces jointes.
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addAttachments(urls)
            return true
        }
        .overlay(alignment: .top) { errorBanner }
        .overlay(alignment: .top) { accessibilityBanner }
        .animation(.spring(duration: 0.3), value: viewModel.errorText)
        .animation(.spring(duration: 0.3), value: windowManager.needsAccessibility)
        .onReceive(NotificationCenter.default.publisher(for: .newSessionRequested)) { _ in
            viewModel.newSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockToIDERequested)) { _ in
            windowManager.dockToDefaultTarget()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maximizePairRequested)) { _ in
            windowManager.maximizePair()
        }
    }

    // MARK: - Fil de conversation

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack et NON LazyVStack : le Lazy met en cache la hauteur
                // d'une ligne à sa première apparition et ne la réévalue pas
                // quand son contenu grandit. Or c'est précisément ce qui arrive
                // ici — une bulle s'allonge à chaque delta —, d'où des réponses
                // longues tronquées, que seul un passage sur une autre session
                // (qui détruit les vues) réparait. La paresse coûtait plus
                // qu'elle ne rapportait : un fil de conversation reste court,
                // et SwiftUI ne recalcule de toute façon que la bulle modifiée.
                VStack(alignment: .leading, spacing: 16) {
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
            // Défilement SANS animation : pendant le streaming, la révision
            // change plusieurs fois par seconde — empiler des animations de
            // scroll saturait le thread principal (l'UI semblait figée).
            .onChange(of: viewModel.revision) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
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

    /// L'ancrage tuilé exige la permission Accessibilité : macOS n'affiche son
    /// alerte qu'UNE fois par app, et ne prévient jamais quand l'utilisateur
    /// accorde le droit. D'où cette bannière persistante + une revérification
    /// au retour dans l'app (onAppActivated), seul moment fiable pour la voir
    /// disparaître.
    @ViewBuilder
    private var accessibilityBanner: some View {
        if windowManager.needsAccessibility {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Autorisez l'Accessibilité pour l'ancrage complet")
                        .font(.callout.weight(.medium))
                    Text("Sans ce droit, le compagnon se pose à côté de l'IDE sans pouvoir le redimensionner ni le suivre.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Ouvrir") { Accessibility.openSettings() }
                    .buttonStyle(.borderless)
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14), tint: .orange)
            .padding(.horizontal, 16)
            .padding(.top, 46)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in
                if Accessibility.isTrusted { windowManager.needsAccessibility = false }
            }
        }
    }

    /// Une seule bannière pour les erreurs du CLI et celles de l'ancrage :
    /// deux bandeaux rouges empilés au même endroit se marcheraient dessus.
    @ViewBuilder
    private var errorBanner: some View {
        if let errorText = viewModel.errorText ?? windowManager.dockError {
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
                    windowManager.dockError = nil
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
}

extension Notification.Name {
    static let newSessionRequested = Notification.Name("ClaudeCompanion.newSession")
    static let dockToIDERequested = Notification.Name("ClaudeCompanion.dockToIDE")
    static let maximizePairRequested = Notification.Name("ClaudeCompanion.maximizePair")
}

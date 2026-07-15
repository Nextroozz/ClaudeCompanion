import SwiftUI

/// Petite capsule de verre affichée entre le fil de conversation et la barre
/// de saisie pendant qu'une réponse est en cours : une étincelle qui pulse
/// suivie du verbe d'activité courant (« Réfléchit », « Code », « Exécute »…),
/// fourni par ChatViewModel.currentActivity.
struct ActivityIndicatorView: View {
    let activity: String
    /// Complément vivant (ex. « ~750 tokens » pendant une réflexion chiffrée,
    /// dont le texte n'est jamais transmis — voir ChatViewModel.thinkingTokens).
    var detail: String?
    /// Le Pong d'attente. Affiché tant que Claude travaille SANS rien écrire —
    /// réflexion, outils. Pendant la rédaction, le texte défile : le jeu
    /// deviendrait une distraction là où il y a justement à lire.
    var showsGame = false

    /// Pilote la pulsation de l'étincelle (opacité + échelle en boucle).
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [.accentColor, .purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .scaleEffect(pulsing ? 1.0 : 0.82)
                .opacity(pulsing ? 1.0 : 0.55)
            Text("\(activity)…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                // Le verbe change au fil des outils : fondu plutôt que saut sec.
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: activity)

            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    // numericText : le compteur défile au lieu de clignoter.
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: detail)
            }

            if showsGame {
                PongWaitingView()
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

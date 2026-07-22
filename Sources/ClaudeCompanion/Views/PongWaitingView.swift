import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// PongWaitingView — le petit jeu qui tourne pendant que Claude réfléchit
//
// Le texte de la réflexion des modèles actuels est chiffré : il n'arrive jamais
// (voir ClaudeEvent.thinkingDelta). L'attente est donc un vrai trou — parfois
// trente secondes de bulle vide. Ce Pong joue tout seul pour le combler.
//
// Aucun Timer, aucun état : la position se DÉDUIT de l'horloge fournie par
// TimelineView. Trois bénéfices concrets :
//   • rien à démarrer ni à arrêter — la vue disparaît, tout s'arrête ;
//   • pas de dérive ni de rattrapage si une frame saute ;
//   • aucun risque de cycle de rétention (pas de closure qui capture self).
// ─────────────────────────────────────────────────────────────────────────────

struct PongWaitingView: View {

    /// 24 fps : largement fluide pour deux raquettes, et on ne vole pas le CPU
    /// au streaming (qui, lui, rafraîchit l'UI en continu).
    private static let frameInterval = 1.0 / 24.0

    /// Périodes dans le rapport du NOMBRE D'OR. Deux périodes égales
    /// donneraient une diagonale ; un rapport rationnel simple ramènerait vite
    /// la balle à son point de départ. φ est l'irrationnel le plus mal
    /// approché par les fractions : c'est donc le rapport qui retarde AU
    /// MAXIMUM la resynchronisation. Mesuré : un premier retour approché à
    /// ~44 s avec 2,3/1,457, aucun sur 46 s avec φ (voir PongGeometryTests).
    private static let periodX = 2.3
    private static let periodY = 2.3 / 1.618_033_988_749_895

    static let ballSize: CGFloat = 4
    private static let paddleWidth: CGFloat = 2

    /// Compact : le jeu vit dans la capsule d'activité, aux côtés du verbe et
    /// du compteur. Il y est visible pendant TOUTE l'attente — y compris les
    /// longues séquences d'outils, où se trouve le vrai temps mort.
    var width: CGFloat = 74
    var height: CGFloat = 14

    /// Raquette proportionnelle : la capsule peut changer de hauteur, une
    /// constante en points la ferait déborder.
    private func paddleHeight(for size: CGSize) -> CGFloat { size.height * 0.5 }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size,
                     time: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true) // décoratif : rien à annoncer à VoiceOver
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let ball = ballPosition(at: time, in: size)

        // Ligne médiane pointillée.
        var mid = Path()
        mid.move(to: CGPoint(x: size.width / 2, y: 2))
        mid.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
        ctx.stroke(mid, with: .color(.secondary.opacity(0.25)),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        // Les raquettes suivent la balle avec un LÉGER retard : viser la
        // position actuelle donnerait un collage parfait, robotique et mort.
        // Ce décalage suffit à évoquer une réaction.
        let paddle = paddleHeight(for: size)
        for (x, lag) in [(CGFloat(1), 0.10), (size.width - 1 - Self.paddleWidth, 0.16)] {
            let tracked = ballPosition(at: time - lag, in: size).y
            let y = min(max(tracked - paddle / 2, 0), size.height - paddle)
            let rect = CGRect(x: x, y: y, width: Self.paddleWidth, height: paddle)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                     with: .color(.secondary.opacity(0.55)))
        }

        ctx.fill(
            Path(ellipseIn: CGRect(x: ball.x, y: ball.y,
                                   width: Self.ballSize, height: Self.ballSize)),
            with: .color(.accentColor)
        )
    }

    /// Un rebond parfaitement élastique EST une onde triangulaire : inutile de
    /// simuler des collisions, il suffit de replier le temps sur la largeur.
    private func ballPosition(at time: TimeInterval, in size: CGSize) -> CGPoint {
        CGPoint(
            x: triangle(time / Self.periodX) * (size.width - Self.ballSize),
            y: triangle(time / Self.periodY) * (size.height - Self.ballSize)
        )
    }

    /// Onde triangulaire de période 1, à valeurs dans 0...1.
    private func triangle(_ x: Double) -> Double {
        let fraction = x - floor(x)
        return fraction < 0.5 ? fraction * 2 : 2 - fraction * 2
    }
}

// Le Canvas ne clippe pas son contenu : une balle hors-cadre baverait sur le
// texte voisin. La trajectoire est du calcul pur, donc testable — on l'expose.
extension PongWaitingView {
    func ballPositionForTesting(at time: TimeInterval, in size: CGSize) -> CGPoint {
        ballPosition(at: time, in: size)
    }
}

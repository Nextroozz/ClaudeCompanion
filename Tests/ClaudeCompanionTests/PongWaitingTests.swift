import XCTest
@testable import ClaudeCompanion

@MainActor
final class PongGeometryTests: XCTestCase {

    /// La balle ne doit jamais déborder du cadre, à aucun instant : un Canvas
    /// ne clippe pas, une balle hors-cadre baverait sur le texte voisin.
    func testBallStaysInsideBoundsOverTime() {
        let view = PongWaitingView()
        let size = CGSize(width: 74, height: 14)

        // ~40 s balayées finement : bien au-delà des deux périodes (2,3 et
        // 1,457 s), donc tous les rebonds et leurs battements sont couverts.
        for step in 0..<4000 {
            let point = view.ballPositionForTesting(at: Double(step) * 0.01, in: size)
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.x, size.width - PongWaitingView.ballSize)
            XCTAssertLessThanOrEqual(point.y, size.height - PongWaitingView.ballSize)
        }
    }

    /// Le motif ne doit pas se répéter : deux périodes commensurables
    /// donneraient une diagonale, et un rapport rationnel simple ramènerait
    /// vite la balle au départ. Ce test a réellement pris en défaut un premier
    /// choix (2,3 / 1,457 → retour approché dès ~44 s), d'où le nombre d'or.
    func testTrajectoryDoesNotRepeatQuickly() {
        let view = PongWaitingView()
        let size = CGSize(width: 74, height: 14)
        let start = view.ballPositionForTesting(at: 0, in: size)

        // À chaque période en X, la balle revient à son bord de départ ; c'est
        // Y qui doit avoir dérivé. On balaie 20 périodes ≈ 46 s, soit bien plus
        // qu'une pause de réflexion réelle.
        for step in 1...20 {
            let point = view.ballPositionForTesting(at: Double(step) * 2.3, in: size)
            XCTAssertGreaterThan(abs(point.y - start.y), 0.5,
                                 "resynchronisation à la période \(step) : motif répétitif")
        }
    }
}

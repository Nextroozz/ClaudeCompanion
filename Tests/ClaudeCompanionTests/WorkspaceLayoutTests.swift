import AppKit
import XCTest
@testable import ClaudeCompanion

/// Le layout du workspace est du calcul pur : c'est précisément pourquoi il est
/// séparé du pilotage AX, qui lui n'est pas testable sans un vrai IDE et la
/// permission Accessibilité. Les deux garanties qui comptent — pas de trou,
/// pas de tuile écrasée — se vérifient donc ici, exhaustivement.
final class WorkspaceLayoutTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)

    private func workspace(_ weights: [Double], axis: Workspace.Axis = .horizontal) -> Workspace {
        Workspace(
            tiles: weights.enumerated().map { WorkspaceTile(bundleID: "app.\($0.offset)", weight: $0.element) },
            axis: axis
        )
    }

    // MARK: - Pas de trou, pas de recouvrement

    /// L'invariant central, hérité de l'ancrage à deux : les tuiles se touchent
    /// exactement. Un pixel de trou laisserait voir le bureau au milieu du
    /// workspace ; un pixel de recouvrement ferait clignoter les ombres.
    func testTilesAreFlushAndCoverTheWholeFrame() {
        // Écran large : sur les 1512 pt du portable, 4 tuiles (4 × 380 = 1520)
        // ne rentrent pas et le layout refuse — comportement correct, vérifié
        // par testRefusesToTileWhenItCannotFit. Ici on veut l'invariant.
        let wide = NSRect(x: 0, y: 0, width: 3000, height: 949)
        for count in 1...5 {
            let frames = workspace(Array(repeating: 1, count: count)).frames(in: wide)
            XCTAssertEqual(frames.count, count)

            XCTAssertEqual(frames.first!.minX, wide.minX, "trou à gauche")
            XCTAssertEqual(frames.last!.maxX, wide.maxX, "trou à droite")
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001,
                               "trou ou recouvrement entre deux tuiles (\(count) tuiles)")
            }
        }
    }

    /// La limite réelle de ton écran : 3 tuiles tiennent dans 1512 pt, pas 4.
    /// C'est une contrainte de conception, pas un bug — un workspace à 4 apps
    /// demande un écran externe.
    func testLaptopScreenFitsThreeTilesNotFour() {
        XCTAssertEqual(workspace([1, 1, 1]).frames(in: screen).count, 3)
        XCTAssertTrue(workspace([1, 1, 1, 1]).frames(in: screen).isEmpty,
                      "4 × 380 = 1520 pt > 1512 pt : refus attendu")
    }

    /// Même exigence sur l'axe vertical, où AppKit compte à l'envers : c'est là
    /// qu'une erreur de signe se cacherait.
    func testVerticalTilesAreFlushAndOrderedTopDown() {
        let frames = workspace([1, 1, 1], axis: .vertical).frames(in: screen)

        XCTAssertEqual(frames.first!.maxY, screen.maxY, "la 1re tuile doit coiffer la pile")
        XCTAssertEqual(frames.last!.minY, screen.minY)
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(upper.minY, lower.maxY, accuracy: 0.001, "trou vertical")
            XCTAssertGreaterThan(upper.minY, lower.minY, "ordre inversé : AppKit compte vers le haut")
        }
    }

    // MARK: - Poids

    /// Emprise large à dessein : sur 1512 pt, un partage 3:1 mettrait la petite
    /// tuile à 378 pt, sous le plancher, qui la renflouerait et fausserait le
    /// ratio. C'est voulu (voir testMinimumWinsOverTheRatio) — ici on teste la
    /// proportionnalité, donc on se place là où le plancher ne mord pas.
    func testWeightsSplitProportionally() {
        let frames = workspace([3, 1]).frames(in: NSRect(x: 0, y: 0, width: 3000, height: 949))
        XCTAssertEqual(frames[0].width / frames[1].width, 3, accuracy: 0.02)
    }

    /// Quand les deux s'opposent, le plancher gagne : une fenêtre sous sa taille
    /// minimale la refuse et déborde sur sa voisine, ce qui casserait le
    /// tuilage. Un ratio approximatif est un moindre mal.
    func testMinimumWinsOverTheRatio() {
        let frames = workspace([3, 1]).frames(in: screen) // la petite tomberait à 378
        XCTAssertEqual(frames[1].width, Workspace.minimumWidth, accuracy: 0.5)
        XCTAssertLessThan(frames[0].width / frames[1].width, 3.0,
                          "la grande a payé le renflouement")
        XCTAssertEqual(frames.last!.maxX, screen.maxX, accuracy: 0.5)
    }

    /// Un layout exprimé en poids doit se transposer à n'importe quel écran —
    /// c'est ce qui permet de sauvegarder une disposition par projet.
    func testLayoutTransposesToAnyScreen() {
        let big = workspace([2, 1]).frames(in: NSRect(x: 0, y: 0, width: 3000, height: 1000))
        let small = workspace([2, 1]).frames(in: NSRect(x: 0, y: 0, width: 1512, height: 949))
        XCTAssertEqual(big[0].width / big[1].width, small[0].width / small[1].width, accuracy: 0.02)
    }

    /// L'origine de l'emprise doit être respectée : un workspace peut vivre sur
    /// un écran secondaire, dont les coordonnées ne partent pas de zéro.
    func testRespectsFrameOrigin() {
        let offset = NSRect(x: 1512, y: 200, width: 1000, height: 800)
        let frames = workspace([1, 1]).frames(in: offset)
        XCTAssertEqual(frames.first!.minX, 1512)
        XCTAssertEqual(frames.last!.maxX, 2512)
    }

    // MARK: - Le minimum, et ce qui se passe quand ça ne rentre pas

    /// Un poids ridicule ne doit pas produire une fenêtre inutilisable : sous
    /// le minimum, beaucoup d'apps refusent la taille et débordent sur leur
    /// voisine au lieu de rétrécir — le tuilage serait cassé, pas juste laid.
    func testTinyWeightIsLiftedToTheMinimum() {
        let frames = workspace([100, 1]).frames(in: screen)
        XCTAssertEqual(frames[1].width, Workspace.minimumWidth, accuracy: 0.5)
        XCTAssertEqual(frames[0].maxX, frames[1].minX, accuracy: 0.5, "trou après renflouement")
        XCTAssertEqual(frames.last!.maxX, screen.maxX, accuracy: 0.5, "l'emprise doit rester couverte")
    }

    /// Renflouer une tuile peut en faire passer une autre sous le seuil : d'où
    /// l'itération. Trois tuiles serrées sur un écran juste assez large.
    func testMinimumIsEnforcedForEveryTile() {
        let narrow = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = workspace([50, 1, 1]).frames(in: narrow)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.width, Workspace.minimumWidth - 0.5)
        }
        XCTAssertEqual(frames.last!.maxX, narrow.maxX, accuracy: 0.5)
    }

    /// Emprise trop étroite : mieux vaut ne rien faire qu'empiler des fenêtres
    /// illisibles. Le refus est explicite, pas un tuilage dégradé silencieux.
    func testRefusesToTileWhenItCannotFit() {
        let tooNarrow = NSRect(x: 0, y: 0, width: 700, height: 800)
        XCTAssertTrue(workspace([1, 1]).frames(in: tooNarrow).isEmpty,
                      "2 × 380 pt ne tiennent pas dans 700")
    }

    func testEmptyWorkspaceYieldsNothing() {
        XCTAssertTrue(Workspace(tiles: []).frames(in: screen).isEmpty)
    }

    /// Une tuile seule prend tout : c'est le cas « maximiser une app ».
    func testSingleTileTakesEverything() {
        XCTAssertEqual(workspace([1]).frames(in: screen), [screen])
    }

    // MARK: - Persistance

    /// Un layout se sauvegarde par projet et doit survivre à un relancement de
    /// l'IDE — d'où l'identification par bundle ID plutôt que par pid.
    func testWorkspaceSurvivesEncoding() throws {
        let original = workspace([2, 1], axis: .vertical)
        let restored = try JSONDecoder().decode(
            Workspace.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
    }
}

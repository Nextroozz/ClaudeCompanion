import AppKit
import XCTest
@testable import ClaudeCompanion

// Géométrie de l'ancrage tuilé. Ces calculs sont purs et c'est exactement là
// que se logent les bugs coûteux : une erreur de signe dans la conversion
// AX↔AppKit envoie la fenêtre hors de l'écran, un plancher mal borné la fait
// recouvrir l'IDE. Le suivi live (AXObserver) n'est pas testable sans un vrai
// IDE + la permission Accessibilité : il se vérifie à la main.

final class ScreenGeometryTests: XCTestCase {

    /// La conversion AX↔AppKit est sa propre inverse : deux allers-retours
    /// doivent redonner exactement le rectangle de départ.
    func testConversionIsItsOwnInverse() {
        let original = NSRect(x: 120, y: 340, width: 800, height: 600)
        let roundTrip = ScreenGeometry.appKit(from: ScreenGeometry.ax(from: original))
        XCTAssertEqual(roundTrip, original)
    }

    /// Le repère AX compte vers le BAS : une fenêtre collée en haut de l'écran
    /// a y == 0 en AX, et y == hauteur - hauteurFenêtre en AppKit.
    func testTopOfScreenMapsToZeroInAX() throws {
        let height = ScreenGeometry.referenceFrame.height
        try XCTSkipIf(height == 0, "Pas d'écran : environnement sans affichage.")

        let topAligned = NSRect(x: 0, y: height - 500, width: 900, height: 500)
        XCTAssertEqual(ScreenGeometry.ax(from: topAligned).minY, 0, accuracy: 0.001)
    }
}

@MainActor
final class DockLayoutTests: XCTestCase {

    private func manager(side: DockSide, companionWidth: CGFloat) -> WindowManager {
        // Les préférences pilotent le layout : on les fixe pour le test.
        UserDefaults.standard.set(side.rawValue, forKey: "dockSide")
        UserDefaults.standard.set(companionWidth, forKey: "companionWidth")
        return WindowManager()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "dockSide")
        UserDefaults.standard.removeObject(forKey: "companionWidth")
        super.tearDown()
    }

    /// Le découpage conserve l'emprise totale : c'est ce qui fait que l'ancrage
    /// ne « saute » pas — la paire tient pile où l'IDE était.
    func testSplitPreservesFootprintOnTheRight() {
        let combined = NSRect(x: 100, y: 200, width: 1400, height: 900)
        let parts = manager(side: .right, companionWidth: 440).split(combined)

        XCTAssertEqual(parts.ide, NSRect(x: 100, y: 200, width: 960, height: 900))
        XCTAssertEqual(parts.companion, NSRect(x: 1060, y: 200, width: 440, height: 900))
        XCTAssertEqual(parts.ide.maxX, parts.companion.minX, "les deux doivent être flush")
        XCTAssertEqual(parts.ide.union(parts.companion), combined)
    }

    func testSplitPreservesFootprintOnTheLeft() {
        let combined = NSRect(x: 100, y: 200, width: 1400, height: 900)
        let parts = manager(side: .left, companionWidth: 440).split(combined)

        XCTAssertEqual(parts.companion, NSRect(x: 100, y: 200, width: 440, height: 900))
        XCTAssertEqual(parts.ide, NSRect(x: 540, y: 200, width: 960, height: 900))
        XCTAssertEqual(parts.companion.maxX, parts.ide.minX, "les deux doivent être flush")
        XCTAssertEqual(parts.ide.union(parts.companion), combined)
    }

    /// Le plancher du compagnon est aligné sur le minSize de la fenêtre : en
    /// descendre ferait refuser la taille par AppKit, et la fenêtre trop large
    /// recouvrirait l'IDE — exactement le bug qu'on veut éviter.
    func testCompanionNeverGoesBelowItsWindowMinimum() {
        let narrow = manager(side: .right, companionWidth: 440)
            .companionWidth(within: 600) // 600 - 400(IDE) = 200 < 380
        XCTAssertEqual(narrow, WindowManager.minCompanionWidth)
    }

    /// Sur une emprise large, l'IDE garde au moins minIDEWidth.
    func testCompanionIsCappedToLeaveRoomForTheIDE() {
        let width = manager(side: .right, companionWidth: 2000)
            .companionWidth(within: 1400)
        XCTAssertEqual(width, 1400 - WindowManager.minIDEWidth)
    }

    /// L'invariant du mode tuilé, vérifié dans les deux sens.
    func testCompanionIsAlwaysFlushAgainstTheIDE() {
        let ide = NSRect(x: 300, y: 150, width: 900, height: 800)

        let right = manager(side: .right, companionWidth: 440)
            .companionFrame(forIDE: ide, width: 440)
        XCTAssertEqual(right.minX, ide.maxX)
        XCTAssertEqual(right.minY, ide.minY)
        XCTAssertEqual(right.height, ide.height, "hauteur partagée : l'illusion d'une seule app")

        let left = manager(side: .left, companionWidth: 440)
            .companionFrame(forIDE: ide, width: 440)
        XCTAssertEqual(left.maxX, ide.minX)
        XCTAssertEqual(left.height, ide.height)
    }
}

final class NearlyEqualTests: XCTestCase {

    /// La tolérance existe pour absorber les arrondis AX/AppKit — sans elle,
    /// notre propre écho passerait pour un déplacement utilisateur et la paire
    /// entrerait en oscillation.
    func testSubPixelDriftIsNotAUserMove() {
        let a = NSRect(x: 100, y: 100, width: 800, height: 600)
        let b = NSRect(x: 100.4, y: 99.7, width: 800.2, height: 600)
        XCTAssertTrue(a.isNearlyEqual(to: b))
    }

    func testRealMoveIsDetected() {
        let a = NSRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(a.isNearlyEqual(to: a.offsetBy(dx: 4, dy: 0)))
    }
}

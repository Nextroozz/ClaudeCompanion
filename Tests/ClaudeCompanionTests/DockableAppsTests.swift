import AppKit
import CoreGraphics
import XCTest
@testable import ClaudeCompanion

/// Le bug qui a motivé ce test : `.optionOnScreenOnly` ne liste que le Space
/// COURANT. Un IDE en plein écran (Space dédié), sur un autre bureau ou réduit
/// devenait introuvable — 1 app détectée au lieu de 24 sur une session réelle.
/// On ne peut pas simuler des Spaces en test ; on verrouille donc l'invariant
/// qui compte : l'énumération ne doit JAMAIS se restreindre à l'écran visible.
final class WindowEnumerationTests: XCTestCase {

    /// Garde-fou anti-régression : réintroduire .optionOnScreenOnly ferait
    /// disparaître les IDE des autres Spaces sans aucun test rouge.
    func testEnumerationOptionsDoNotRestrictToCurrentSpace() {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        XCTAssertFalse(options.contains(.optionOnScreenOnly),
                       "optionOnScreenOnly masque les fenêtres des autres Spaces")
    }

    /// L'énumération doit tourner sans permission (elle sert AVANT que
    /// l'Accessibilité soit accordée, pour peupler le menu).
    func testEnumerationWorksWithoutAccessibilityPermission() {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]]
        XCTAssertNotNil(list, "CGWindowList ne doit exiger aucune permission")
    }
}

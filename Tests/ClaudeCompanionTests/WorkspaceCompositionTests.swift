import XCTest
@testable import ClaudeCompanion

/// Composition du workspace : add/remove/dédup et le statut particulier du
/// compagnon. Ce sont des mutations d'état pures — le pilotage réel des
/// fenêtres (AX + NSWindow) n'est pas testable sans un vrai écran et la
/// permission Accessibilité, il se vérifie à la main.
@MainActor
final class WorkspaceCompositionTests: XCTestCase {

    func testCompanionIsPresentFromTheStart() {
        let manager = WindowManager()
        XCTAssertEqual(manager.workspace.tiles.count, 1)
        XCTAssertTrue(manager.workspace.tiles.first!.isCompanion)
    }

    func testAddingAnAppAppendsATile() {
        let manager = WindowManager()
        XCTAssertTrue(manager.composeAdd(bundleID: "com.apple.dt.Xcode"))
        XCTAssertEqual(manager.workspace.tiles.map(\.bundleID),
                       [WorkspaceTile.companionBundleID, "com.apple.dt.Xcode"])
    }

    /// Ajouter deux fois la même app ne doit pas créer deux tuiles — sinon la
    /// fenêtre serait « partagée » entre deux cases et le tuilage incohérent.
    func testAddingTheSameAppTwiceIsIgnored() {
        let manager = WindowManager()
        XCTAssertTrue(manager.composeAdd(bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(manager.composeAdd(bundleID: "com.microsoft.VSCode"))
        XCTAssertEqual(manager.workspace.tiles.count, 2)
    }

    func testRemovingAnApp() {
        let manager = WindowManager()
        manager.composeAdd(bundleID: "com.microsoft.VSCode")
        manager.composeRemove(bundleID: "com.microsoft.VSCode")
        XCTAssertEqual(manager.workspace.tiles.count, 1)
        XCTAssertTrue(manager.workspace.tiles.first!.isCompanion)
    }

    /// Le compagnon est indéboulonnable : un workspace sans Claude n'aurait pas
    /// de sens pour cette app, et le retirer laisserait un layout orphelin.
    func testCompanionCannotBeRemoved() {
        let manager = WindowManager()
        manager.composeRemove(bundleID: WorkspaceTile.companionBundleID)
        XCTAssertEqual(manager.workspace.tiles.count, 1)
        XCTAssertTrue(manager.workspace.tiles.first!.isCompanion)
    }

    /// L'ordre d'ajout est l'ordre de tuilage (gauche→droite / haut→bas) : il
    /// doit être préservé, l'utilisateur le voit dans le panneau.
    func testTileOrderFollowsInsertion() {
        let manager = WindowManager()
        manager.composeAdd(bundleID: "b.app")
        manager.composeAdd(bundleID: "a.app")
        XCTAssertEqual(manager.workspace.tiles.map(\.bundleID),
                       [WorkspaceTile.companionBundleID, "b.app", "a.app"])
    }
}

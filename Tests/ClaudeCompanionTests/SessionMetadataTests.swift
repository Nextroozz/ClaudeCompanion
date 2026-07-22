import XCTest
@testable import ClaudeCompanion

/// Magasin de décorations de sessions. On l'isole dans un dossier temporaire —
/// jamais l'Application Support réel de la machine.
@MainActor
final class SessionMetadataTests: XCTestCase {

    private var dir: URL!
    private func makeStore() -> SessionMetadataStore { SessionMetadataStore(directory: dir) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDefaultMetadataIsEmpty() {
        XCTAssertTrue(makeStore().metadata(for: "abc").isEmpty)
    }

    func testSetNameAndColorAndGroup() {
        let store = makeStore()
        store.setName("Refonte auth", for: "s1")
        store.setColor(.blue, for: "s1")
        store.setGroup("Backend", for: "s1")

        let m = store.metadata(for: "s1")
        XCTAssertEqual(m.name, "Refonte auth")
        XCTAssertEqual(m.color, .blue)
        XCTAssertEqual(m.group, "Backend")
    }

    /// Un nom vide ou blanc efface le renommage (retour au titre auto), il ne
    /// s'enregistre pas comme " ".
    func testBlankNameClearsIt() {
        let store = makeStore()
        store.setName("X", for: "s1")
        store.setName("   ", for: "s1")
        XCTAssertNil(store.metadata(for: "s1").name)
    }

    /// Une entrée redevenue entièrement vide est purgée : le JSON ne conserve
    /// que ce qui a du sens.
    func testEmptiedEntryIsForgotten() {
        let store = makeStore()
        store.setColor(.red, for: "s1")
        store.setColor(nil, for: "s1")
        XCTAssertTrue(store.metadata(for: "s1").isEmpty)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testGroupsAreDistinctAndSorted() {
        let store = makeStore()
        store.setGroup("Backend", for: "s1")
        store.setGroup("API", for: "s2")
        store.setGroup("Backend", for: "s3") // doublon volontaire
        XCTAssertEqual(store.groups, ["API", "Backend"])
    }

    /// La persistance : un nouveau store relit ce que le précédent a écrit dans
    /// le même dossier — c'est ce qui fait survivre les décorations au
    /// redémarrage de l'app.
    func testMetadataPersistsAcrossStores() {
        let first = makeStore()
        first.setName("Session importante", for: "s1")
        first.setColor(.green, for: "s1")

        let second = makeStore()
        XCTAssertEqual(second.metadata(for: "s1").name, "Session importante")
        XCTAssertEqual(second.metadata(for: "s1").color, .green)
    }

    func testForgetRemovesEverything() {
        let store = makeStore()
        store.setName("X", for: "s1")
        store.forget("s1")
        XCTAssertTrue(store.metadata(for: "s1").isEmpty)
    }
}

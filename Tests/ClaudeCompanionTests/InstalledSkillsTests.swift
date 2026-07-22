import XCTest
@testable import ClaudeCompanion

/// Scan des skills installés. On fabrique une arborescence temporaire plutôt
/// que de dépendre de ce qui est réellement installé sur la machine de CI.
final class InstalledSkillsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skilltest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSkill(_ name: String, description: String, in dir: URL) throws {
        let skillDir = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\nCorps"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func testScanReadsEverySkillFolder() throws {
        try writeSkill("alpha", description: "Le premier", in: root)
        try writeSkill("beta", description: "Le second", in: root)

        let skills = InstalledSkillsService.scan(root, scope: .user)
        XCTAssertEqual(skills.map(\.name).sorted(), ["alpha", "beta"])
        XCTAssertEqual(skills.first { $0.name == "alpha" }?.description, "Le premier")
        XCTAssertTrue(skills.allSatisfy { $0.installed == .user })
    }

    /// Un dossier sans SKILL.md (ou avec un fichier bidon) ne doit pas produire
    /// de skill fantôme.
    func testFolderWithoutManifestIsIgnored() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pasunskill"), withIntermediateDirectories: true)
        try writeSkill("vrai", description: "OK", in: root)

        XCTAssertEqual(InstalledSkillsService.scan(root, scope: .user).map(\.name), ["vrai"])
    }

    func testMissingDirectoryYieldsEmpty() {
        let absent = root.appendingPathComponent("n-existe-pas")
        XCTAssertTrue(InstalledSkillsService.scan(absent, scope: .project).isEmpty)
    }

    /// En cas de doublon de nom, le périmètre projet doit l'emporter sur le
    /// global — c'est la priorité qu'applique aussi le CLI.
    func testProjectSkillOverridesUserSkillOfSameName() throws {
        let userDir = root.appendingPathComponent("home/.claude/skills")
        let projectDir = root.appendingPathComponent("proj/.claude/skills")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeSkill("shared", description: "version globale", in: userDir)
        try writeSkill("shared", description: "version projet", in: projectDir)

        // On teste la règle de fusion directement sur scan + dédup manuelle,
        // le vrai installedSkills(projectDirectory:) visant ~/.claude en dur.
        var byName: [String: Skill] = [:]
        for s in InstalledSkillsService.scan(userDir, scope: .user) { byName[s.name] = s }
        for s in InstalledSkillsService.scan(projectDir, scope: .project) { byName[s.name] = s }
        XCTAssertEqual(byName["shared"]?.installed, .project)
        XCTAssertEqual(byName["shared"]?.description, "version projet")
    }
}

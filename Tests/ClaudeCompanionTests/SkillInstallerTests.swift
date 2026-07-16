import XCTest
@testable import ClaudeCompanion

/// Logique pure de l'installateur. Les vrais téléchargements réseau se
/// vérifient à la main (ils dépendent de GitHub) ; ici on verrouille ce qui doit
/// l'être sans réseau : détection de scripts et résolution des chemins.
final class SkillInstallerTests: XCTestCase {

    /// Le repérage des scripts nourrit l'alerte de sécurité : un skill comme
    /// « pdf » embarque 8 scripts Python que Claude exécutera. Se tromper ici,
    /// c'est installer du code exécutable sans prévenir.
    func testScriptDetection() {
        XCTAssertTrue(SkillInstaller.SkillFile(relativePath: "scripts/run.py").isScript)
        XCTAssertTrue(SkillInstaller.SkillFile(relativePath: "hook.sh").isScript)
        XCTAssertTrue(SkillInstaller.SkillFile(relativePath: "tool.js").isScript)
        XCTAssertFalse(SkillInstaller.SkillFile(relativePath: "SKILL.md").isScript)
        XCTAssertFalse(SkillInstaller.SkillFile(relativePath: "reference.md").isScript)
        XCTAssertFalse(SkillInstaller.SkillFile(relativePath: "LICENSE.txt").isScript)
    }

    /// Périmètre projet → sous .claude/skills DU PROJET ; global → ~/.claude.
    /// Se tromper poserait le skill là où le CLI ne le chargerait pas pour ce
    /// projet.
    func testDestinationRootHonoursScope() {
        let project = URL(fileURLWithPath: "/tmp/mon-projet")

        let projectRoot = SkillInstaller.destinationRoot(scope: .project, projectDirectory: project)
        XCTAssertEqual(projectRoot.path, "/tmp/mon-projet/.claude/skills")

        let userRoot = SkillInstaller.destinationRoot(scope: .user, projectDirectory: project)
        XCTAssertTrue(userRoot.path.hasSuffix("/.claude/skills"))
        XCTAssertFalse(userRoot.path.contains("mon-projet"))
    }

    /// Désinstaller un skill de plugin doit échouer proprement : il appartient à
    /// son plugin et réapparaîtrait à la prochaine synchro.
    func testUninstallingPluginSkillThrows() {
        let pluginSkill = Skill(name: "x", description: "", origin: .local, installed: .plugin)
        XCTAssertThrowsError(try SkillInstaller.uninstall(pluginSkill,
                                                          projectDirectory: URL(fileURLWithPath: "/tmp"))) { error in
            XCTAssertEqual(error as? SkillInstaller.InstallError, .notRemovable)
        }
    }
}

extension SkillInstaller.InstallError: Equatable {
    public static func == (l: SkillInstaller.InstallError, r: SkillInstaller.InstallError) -> Bool {
        String(describing: l) == String(describing: r)
    }
}

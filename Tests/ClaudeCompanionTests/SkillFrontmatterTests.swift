import XCTest
@testable import ClaudeCompanion

/// Parsing du frontmatter d'un SKILL.md. Les exemples proviennent de vrais
/// skills officiels (anthropics/skills) — c'est ce que l'app rencontrera.
final class SkillFrontmatterTests: XCTestCase {

    /// Cas réel capturé de anthropics/skills/frontend-design : le frontmatter
    /// porte name, description ET license — on ne veut que les deux premiers.
    func testParsesRealOfficialSkill() {
        let content = """
        ---
        name: frontend-design
        description: Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one.
        license: Complete terms in LICENSE.txt
        ---

        # Frontend Design
        Le corps du skill…
        """
        let parsed = SkillFrontmatter.parse(content)
        XCTAssertEqual(parsed?.name, "frontend-design")
        XCTAssertTrue(parsed?.description.hasPrefix("Guidance for distinctive") ?? false)
    }

    func testParsesQuotedValues() {
        let content = "---\nname: \"my-skill\"\ndescription: 'Fait des choses'\n---\nCorps"
        let parsed = SkillFrontmatter.parse(content)
        XCTAssertEqual(parsed?.name, "my-skill")
        XCTAssertEqual(parsed?.description, "Fait des choses")
    }

    /// Une description sur plusieurs lignes (continuation indentée) ne doit pas
    /// faire fuiter les lignes suivantes dans d'autres clés.
    func testIgnoresIndentedContinuationLines() {
        let content = """
        ---
        name: multi
        description: Première ligne
          suite indentée qui ne doit pas devenir une clé
        version: 1
        ---
        """
        let fields = SkillFrontmatter.fields(in: content)
        XCTAssertEqual(fields?["name"], "multi")
        XCTAssertEqual(fields?["version"], "1")
        XCTAssertNil(fields?["suite indentée qui ne doit pas devenir une clé"])
    }

    /// Sans bloc frontmatter, pas de skill exploitable.
    func testRejectsContentWithoutFrontmatter() {
        XCTAssertNil(SkillFrontmatter.parse("# Juste un titre\ndu texte"))
    }

    /// Un frontmatter sans nom est inexploitable (le nom = le dossier).
    func testRejectsFrontmatterWithoutName() {
        XCTAssertNil(SkillFrontmatter.parse("---\ndescription: orpheline\n---\n"))
    }

    /// Le frontmatter doit ouvrir le fichier : un bloc `---` au milieu du corps
    /// (règle horizontale Markdown) ne doit pas être pris pour des métadonnées.
    func testDoesNotParseHorizontalRuleInBody() {
        XCTAssertNil(SkillFrontmatter.parse("# Titre\n\nTexte\n\n---\n\nSuite"))
    }
}

final class SkillModelTests: XCTestCase {

    func testInstalledUserSkillIsRemovable() {
        let skill = Skill(name: "x", description: "", origin: .local, installed: .user)
        XCTAssertTrue(skill.isInstalled)
        XCTAssertTrue(skill.isRemovable)
    }

    /// Un skill fourni par un plugin appartient à son plugin : on ne le retire
    /// pas depuis ici, sous peine de le voir réapparaître à la prochaine synchro.
    func testPluginSkillIsNotRemovable() {
        let skill = Skill(name: "x", description: "", origin: .local, installed: .plugin)
        XCTAssertTrue(skill.isInstalled)
        XCTAssertFalse(skill.isRemovable)
    }

    func testCatalogSkillNotInstalled() {
        let skill = Skill(name: "x", description: "", origin: .official, installed: nil)
        XCTAssertFalse(skill.isInstalled)
        XCTAssertFalse(skill.isRemovable)
    }
}

import XCTest
@testable import ClaudeCompanion

/// Mappage signaux → suggestions. C'est du pur calcul, séparé de la lecture
/// disque exprès pour être testable exhaustivement.
final class SkillSuggesterTests: XCTestCase {

    /// Catalogue de test : les noms doivent matcher ceux des règles.
    private let catalog: [Skill] = [
        "frontend-design", "web-artifacts-builder", "webapp-testing",
        "mcp-builder", "claude-api", "skill-creator", "pdf", "docx",
    ].map { Skill(name: $0, description: "desc de \($0)", origin: .official, installed: nil) }

    func testReactProjectSuggestsFrontendSkills() {
        var signals = ProjectSignals()
        signals.hasReact = true
        let names = SkillSuggester.suggestions(for: signals, catalog: catalog, installed: [])
            .map(\.skill.name)
        XCTAssertTrue(names.contains("frontend-design"))
        XCTAssertTrue(names.contains("webapp-testing"))
    }

    /// On ne propose jamais un skill déjà installé — ce serait du bruit.
    func testAlreadyInstalledSkillsAreNotSuggested() {
        var signals = ProjectSignals()
        signals.hasReact = true
        let names = SkillSuggester.suggestions(for: signals, catalog: catalog,
                                               installed: ["frontend-design"]).map(\.skill.name)
        XCTAssertFalse(names.contains("frontend-design"))
        XCTAssertTrue(names.contains("web-artifacts-builder"))
    }

    /// Deux règles peuvent viser le même skill : il ne doit apparaître qu'une
    /// fois, et garder la raison de la PREMIÈRE règle qui l'a proposé.
    func testNoDuplicateSuggestions() {
        var signals = ProjectSignals()
        signals.hasReact = true
        signals.fileExtensions = ["tsx"] // la règle 1 matche aussi via tsx
        let suggestions = SkillSuggester.suggestions(for: signals, catalog: catalog, installed: [])
        let frontend = suggestions.filter { $0.skill.name == "frontend-design" }
        XCTAssertEqual(frontend.count, 1)
    }

    func testMCPProjectSuggestsMCPBuilder() {
        var signals = ProjectSignals()
        signals.usesMCP = true
        XCTAssertEqual(
            SkillSuggester.suggestions(for: signals, catalog: catalog, installed: []).map(\.skill.name),
            ["mcp-builder"]
        )
    }

    func testDocumentExtensionsSuggestDocumentSkills() {
        var signals = ProjectSignals()
        signals.fileExtensions = ["pdf", "docx"]
        let names = Set(SkillSuggester.suggestions(for: signals, catalog: catalog, installed: []).map(\.skill.name))
        XCTAssertEqual(names, ["pdf", "docx"])
    }

    /// Un projet sans signal ne propose rien — pas de suggestion au hasard.
    func testEmptyProjectSuggestsNothing() {
        XCTAssertTrue(SkillSuggester.suggestions(for: ProjectSignals(), catalog: catalog, installed: []).isEmpty)
    }

    /// Une suggestion pointant un skill absent du catalogue est ignorée (le
    /// catalogue peut être vide si GitHub est injoignable).
    func testSuggestionsRequireACatalogEntry() {
        var signals = ProjectSignals()
        signals.hasReact = true
        XCTAssertTrue(SkillSuggester.suggestions(for: signals, catalog: [], installed: []).isEmpty)
    }

    func testEachSuggestionCarriesAReason() {
        var signals = ProjectSignals()
        signals.usesMCP = true
        XCTAssertEqual(SkillSuggester.suggestions(for: signals, catalog: catalog, installed: []).first?.reason,
                       "Serveur MCP dans le projet")
    }
}

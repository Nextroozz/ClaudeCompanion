import XCTest
@testable import ClaudeCompanion

/// Analyse des résultats de code-search. C'est du parsing pur (les appels
/// réseau se vérifient à la main) : une erreur ici pointerait l'install vers le
/// mauvais dossier ou la mauvaise révision.
final class SkillSearchTests: XCTestCase {

    /// Le dossier du skill = le chemin sans le fichier SKILL.md.
    func testFolderPathStripsTheFilename() {
        XCTAssertEqual(SkillSearchService.folderPath(of: "skills/foo/SKILL.md"), "skills/foo")
        XCTAssertEqual(SkillSearchService.folderPath(of: ".claude/skills/bar/SKILL.md"), ".claude/skills/bar")
    }

    /// Un SKILL.md à la RACINE du dépôt → dossier vide (l'install saura que le
    /// skill EST le dépôt, avec le garde-fou de taille).
    func testRootLevelSkillHasEmptyFolder() {
        XCTAssertEqual(SkillSearchService.folderPath(of: "SKILL.md"), "")
    }

    /// La révision vient de l'html_url du blob : GitHub y met le SHA du commit,
    /// donc l'install pointe EXACTEMENT ce qui a été prévisualisé — insensible à
    /// un push ultérieur sur la branche.
    func testReferenceExtractedFromBlobURL() {
        let url = "https://github.com/owner/repo/blob/a1b2c3d4/skills/foo/SKILL.md"
        XCTAssertEqual(SkillSearchService.referenceFromBlobURL(url), "a1b2c3d4")
    }

    func testReferenceWithBranchName() {
        let url = "https://github.com/owner/repo/blob/main/SKILL.md"
        XCTAssertEqual(SkillSearchService.referenceFromBlobURL(url), "main")
    }

    /// Une URL sans segment /blob/ ne doit pas produire de référence bancale.
    func testMalformedURLYieldsNil() {
        XCTAssertNil(SkillSearchService.referenceFromBlobURL("https://github.com/owner/repo"))
        XCTAssertNil(SkillSearchService.referenceFromBlobURL("n'importe quoi"))
    }
}

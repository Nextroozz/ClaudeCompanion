import XCTest
@testable import ClaudeCompanion

/// Ces tests figent une leçon payée cash : le Pong avait d'abord été placé
/// dans la bulle vide, donc visible seulement pendant la réflexion — 0,3 s sur
/// une question simple, et JAMAIS pendant les outils, là où l'attente est
/// réellement longue. L'utilisateur l'a signalé comme « ne fonctionne pas ».
@MainActor
final class WaitingStateTests: XCTestCase {

    /// Le cas qui avait été manqué : une longue séquence d'outils est une
    /// attente, et doit donc occuper l'utilisateur.
    func testToolExecutionCountsAsWaiting() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.activityVerb(forTool: "Bash")
        XCTAssertTrue(model.isWaiting, "les outils sont le vrai temps mort")
    }

    func testThinkingCountsAsWaiting() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.thinkingVerb
        XCTAssertTrue(model.isWaiting)
    }

    /// Pendant la rédaction, le texte défile : le jeu deviendrait une
    /// distraction là où il y a justement quelque chose à lire.
    func testWritingIsNotWaiting() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.writingVerb
        XCTAssertFalse(model.isWaiting, "du texte arrive : plus rien à meubler")
    }

    /// Hors tour, aucune animation ne doit tourner.
    func testIdleIsNotWaiting() {
        let model = ChatViewModel()
        model.currentActivity = nil
        XCTAssertFalse(model.isWaiting)
    }

    /// Le compteur doit SURVIVRE à la réflexion. Le restreindre au verbe
    /// « Réfléchit » le rendait invisible : sur une question simple la
    /// réflexion dure 0,3 s. C'est le bug signalé — « le compteur ne
    /// fonctionne pas » —, alors que la valeur était juste, mais fugace.
    func testTokenCounterSurvivesTheThinkingPhase() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.thinkingVerb
        model.applyThinkingProgressForTesting(tokens: 150)
        XCTAssertEqual(model.activityDetail, "~150 tk")

        model.currentActivity = ChatViewModel.activityVerb(forTool: "Bash")
        XCTAssertEqual(model.activityDetail, "~150 tk",
                       "combien Claude a réfléchi reste vrai pendant ses outils")
    }

    /// Sans réflexion, pas de compteur : « ~0 tk » ne dirait rien.
    func testNoCounterWithoutThinking() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.writingVerb
        XCTAssertNil(model.activityDetail)
    }

    /// Les `estimated_tokens` du flux sont INCRÉMENTAUX : ils s'additionnent.
    /// Les traiter comme cumulés afficherait le dernier fragment seul.
    func testThinkingTokensAccumulate() {
        let model = ChatViewModel()
        model.currentActivity = ChatViewModel.thinkingVerb
        for tokens in [50, 50, 150, 100] {
            model.applyThinkingProgressForTesting(tokens: tokens)
        }
        XCTAssertEqual(model.activityDetail, "~350 tk")
    }
}

/// Le chronomètre : « depuis combien de temps ça réfléchit ».
final class ElapsedFormatTests: XCTestCase {

    func testSecondsBelowAMinute() {
        let start = Date()
        XCTAssertEqual(ActivityIndicatorView.elapsed(from: start, to: start), "0s")
        XCTAssertEqual(ActivityIndicatorView.elapsed(from: start,
                                                    to: start.addingTimeInterval(12)), "12s")
    }

    func testMinutesAreZeroPadded() {
        let start = Date()
        XCTAssertEqual(ActivityIndicatorView.elapsed(from: start,
                                                     to: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(ActivityIndicatorView.elapsed(from: start,
                                                     to: start.addingTimeInterval(125)), "2:05")
    }

    /// Une horloge qui recule (ajustement NTP) ne doit pas afficher « -3s ».
    func testClockGoingBackwardsClampsToZero() {
        let start = Date()
        XCTAssertEqual(ActivityIndicatorView.elapsed(from: start,
                                                     to: start.addingTimeInterval(-3)), "0s")
    }
}

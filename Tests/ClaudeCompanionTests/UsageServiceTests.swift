import XCTest
@testable import ClaudeCompanion

final class UsageServiceTests: XCTestCase {

    func testPricingSelection() {
        XCTAssertEqual(UsageService.pricing(for: "claude-fable-5").input, 10)
        XCTAssertEqual(UsageService.pricing(for: "claude-fable-5").output, 50)
        XCTAssertEqual(UsageService.pricing(for: "claude-opus-4-8").input, 5)
        XCTAssertEqual(UsageService.pricing(for: "claude-sonnet-5").output, 15)
        XCTAssertEqual(UsageService.pricing(for: "claude-haiku-4-5-20251001").input, 1)
        // Dérivés cache : lecture 0,1× / écriture 5 min 1,25× / écriture 1 h 2×.
        let fable = UsageService.pricing(for: "claude-fable-5")
        XCTAssertEqual(fable.cacheRead, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fable.cacheWrite5m, 12.5, accuracy: 1e-9)
        XCTAssertEqual(fable.cacheWrite1h, 20.0, accuracy: 1e-9)
    }

    func testParseEventComputesCostWithCacheBreakdown() {
        let line = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-07-14T10:00:00.000Z","sessionId":"s1","message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":700,"cache_creation":{"ephemeral_5m_input_tokens":500,"ephemeral_1h_input_tokens":200}}}}
        """
        let event = UsageService.parseEvent(line: line)
        XCTAssertNotNil(event)
        // (2×10 + 100×50 + 1000×1 + 500×12,5 + 200×20) / 1e6 = 0,01627 $
        XCTAssertEqual(event!.costUSD, 0.01627, accuracy: 1e-9)
        XCTAssertEqual(event!.cacheWrite5mTokens, 500)
        XCTAssertEqual(event!.cacheWrite1hTokens, 200)
    }

    func testSyntheticModelAndNonAssistantLinesAreIgnored() {
        let synthetic = """
        {"type":"assistant","requestId":"req_2","timestamp":"2026-07-14T10:00:00.000Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5}}}
        """
        XCTAssertNil(UsageService.parseEvent(line: synthetic))
        let user = """
        {"type":"user","timestamp":"2026-07-14T10:00:00.000Z","message":{"role":"user","content":"salut"}}
        """
        XCTAssertNil(UsageService.parseEvent(line: user))
    }

    func testSnapshotDeduplicatesAndBucketsByPeriod() throws {
        let now = try XCTUnwrap(UsageService.parseDate("2026-07-14T12:00:00.000Z"))

        func line(id: String, ts: String, output: Int) -> String {
            """
            {"type":"assistant","requestId":"\(id)","timestamp":"\(ts)","message":{"id":"m-\(id)","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":\(output)}}}
            """
        }

        // req_a apparaît deux fois (ligne partielle puis finale) : la dernière gagne.
        var events: [String: UsageEvent] = [:]
        for raw in [
            line(id: "req_a", ts: "2026-07-14T11:00:00.000Z", output: 10),
            line(id: "req_a", ts: "2026-07-14T11:00:00.000Z", output: 40),   // finale
            line(id: "req_b", ts: "2026-07-14T01:00:00.000Z", output: 100),  // aujourd'hui, hors 5 h
            line(id: "req_c", ts: "2026-07-10T12:00:00.000Z", output: 100),  // dans les 7 jours
            line(id: "req_d", ts: "2026-06-01T12:00:00.000Z", output: 100),  // trop vieux
        ] {
            if let event = UsageService.parseEvent(line: raw) {
                events[event.id] = event
            }
        }

        let snapshot = UsageService.snapshot(from: Array(events.values), now: now)
        XCTAssertEqual(snapshot.lastFiveHours.requests, 1)
        XCTAssertEqual(snapshot.lastFiveHours.outputTokens, 40, "la ligne finale doit remplacer la partielle")
        // « Aujourd'hui » dépend du fuseau local : au moins req_a, jamais req_c/req_d.
        XCTAssertGreaterThanOrEqual(snapshot.today.requests, 1)
        XCTAssertLessThanOrEqual(snapshot.today.requests, 2)
        XCTAssertEqual(snapshot.lastSevenDays.requests, 3)
        XCTAssertEqual(snapshot.lastSevenDays.outputTokens, 240)
        XCTAssertEqual(snapshot.todayByModel.first?.model, "claude-opus-4-8")
    }

    func testModelNameShortening() {
        XCTAssertEqual(ModelNames.short("claude-sonnet-5-20250929"), "sonnet-5")
        XCTAssertEqual(ModelNames.short("claude-fable-5"), "fable-5")
    }
}

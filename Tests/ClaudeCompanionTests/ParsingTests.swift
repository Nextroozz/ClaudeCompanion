import XCTest
@testable import ClaudeCompanion

// MARK: - ANSIStripper

final class ANSIStripperTests: XCTestCase {

    func testStripsSGRColorCodes() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[31mrouge\u{1B}[0m normal"), "rouge normal")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[1;38;5;208mgras orange\u{1B}[m"), "gras orange")
    }

    func testStripsOSCSequences() {
        // Titre de fenêtre (terminé par BEL) et hyperlien OSC 8 (terminé par ST).
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;mon titre\u{07}texte"), "texte")
        XCTAssertEqual(
            ANSIStripper.strip("\u{1B}]8;;https://example.com\u{1B}\\lien\u{1B}]8;;\u{1B}\\"),
            "lien"
        )
    }

    func testStripsCursorAndEraseSequences() {
        XCTAssertEqual(ANSIStripper.strip("a\u{1B}[2K\u{1B}[1Gb\u{1B}[?25l"), "ab")
    }

    func testResolvesCarriageReturnsLikeATerminal() {
        // Une barre de progression réécrit sa ligne : seul l'état final compte.
        XCTAssertEqual(ANSIStripper.strip("Progression 10%\rProgression 100%"), "Progression 100%")
        XCTAssertEqual(ANSIStripper.strip("ligne1\nab\rc\nligne3"), "ligne1\nc\nligne3")
    }

    func testPreservesPlainTextTabsAndNewlines() {
        let plain = "def main():\n\treturn 42\n"
        XCTAssertEqual(ANSIStripper.strip(plain), plain)
    }

    func testStripsSimpleEscapesAndCharsetDesignation() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}(Bfoo\u{1B}=bar"), "foobar")
    }
}

// MARK: - MarkdownBlockParser

final class MarkdownBlockParserTests: XCTestCase {

    func testParagraphsAndHeading() {
        let blocks = MarkdownBlockParser.parse("# Titre\n\nUn paragraphe\nsur deux lignes.")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Titre"),
            .paragraph("Un paragraphe\nsur deux lignes."),
        ])
    }

    func testFencedCodeBlockWithLanguage() {
        let blocks = MarkdownBlockParser.parse("Avant\n```swift\nlet x = 1\n```\nAprès")
        XCTAssertEqual(blocks, [
            .paragraph("Avant"),
            .codeBlock(language: "swift", code: "let x = 1"),
            .paragraph("Après"),
        ])
    }

    func testUnclosedFenceIsRenderedAsCode() {
        // Cas critique : PENDANT le streaming, la fence fermante n'est pas
        // encore arrivée — le code partiel doit rester visible.
        let blocks = MarkdownBlockParser.parse("```python\nprint(1)")
        XCTAssertEqual(blocks, [.codeBlock(language: "python", code: "print(1)")])
    }

    func testLists() {
        let blocks = MarkdownBlockParser.parse("- un\n- deux\n\n1. premier\n2. second")
        XCTAssertEqual(blocks, [
            .bulletList(["un", "deux"]),
            .numberedList(["premier", "second"]),
        ])
    }

    func testQuoteAndRule() {
        let blocks = MarkdownBlockParser.parse("> citation\n\n---")
        XCTAssertEqual(blocks, [.quote("citation"), .rule])
    }

    func testHashInsideCodeIsNotAHeading() {
        let blocks = MarkdownBlockParser.parse("```sh\n# commentaire\n```")
        XCTAssertEqual(blocks, [.codeBlock(language: "sh", code: "# commentaire")])
    }
}

// MARK: - ClaudeEventDecoder (flux stream-json)

final class ClaudeEventDecoderTests: XCTestCase {

    func testDecodesInitEvent() {
        let line = #"{"type":"system","subtype":"init","cwd":"/tmp/demo","session_id":"abc-123","tools":["Bash","Read"],"model":"claude-sonnet-5","permissionMode":"acceptEdits","slash_commands":["/compact","/init"]}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.initialized(sessionID: "abc-123", model: "claude-sonnet-5",
                          slashCommands: ["/compact", "/init"])]
        )
    }

    /// Ligne CAPTURÉE telle quelle depuis le CLI (Opus 4.8). Les modèles
    /// actuels chiffrent leur réflexion : `thinking` est vide, le contenu vit
    /// dans `signature`. Seul `estimated_tokens` est exploitable — d'où un
    /// événement de progression et AUCUN thinkingDelta.
    func testEncryptedThinkingYieldsProgressOnly() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":150}}}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.thinkingProgress(estimatedTokens: 150)]
        )
    }

    /// Les modèles qui exposent leur réflexion en clair (Sonnet 4.6 et
    /// antérieurs) doivent continuer à la streamer, texte ET progression.
    func testPlainThinkingYieldsBothTextAndProgress() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Voyons voir","estimated_tokens":50}}}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.thinkingDelta("Voyons voir"), .thinkingProgress(estimatedTokens: 50)]
        )
    }

    /// Un delta sans compteur ne doit pas produire de progression à zéro, qui
    /// ferait clignoter « ~0 tokens ».
    func testThinkingWithoutTokenCountYieldsNothing() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: line), [])
    }

    func testDecodesInitEventWithoutSlashCommands() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-sonnet-5"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.initialized(sessionID: "abc-123", model: "claude-sonnet-5", slashCommands: [])]
        )
    }

    func testDecodesAssistantTextMessage() {
        let line = #"{"type":"assistant","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"Bonjour **toi**"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"abc-123"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.assistantMessage(id: "msg_01", segments: [.text("Bonjour **toi**")])]
        )
    }

    func testDecodesToolUseWithDetail() {
        let line = #"{"type":"assistant","message":{"id":"msg_02","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file_path":"/tmp/a.swift"}}]},"session_id":"abc-123"}"#
        let events = ClaudeEventDecoder.decode(line: line)
        guard case .assistantMessage(_, let segments)? = events.first,
              case .tool(let call)? = segments.first else {
            return XCTFail("tool_use non décodé : \(events)")
        }
        XCTAssertEqual(call.id, "toolu_01")
        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.detail, "/tmp/a.swift")
        XCTAssertEqual(call.status, .running)
    }

    func testDecodesToolResult() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"contenu","is_error":false}]},"session_id":"abc-123"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.toolFinished(toolUseID: "toolu_01", isError: false, output: "contenu")]
        )
    }

    func testDecodesToolResultWithBlockArrayContent() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":[{"type":"text","text":"ligne 1"},{"type":"text","text":"ligne 2"}],"is_error":true}]},"session_id":"abc"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.toolFinished(toolUseID: "toolu_02", isError: true, output: "ligne 1\nligne 2")]
        )
    }

    func testToolInputDisplayFormatting() {
        let bash = ClaudeEventDecoder.toolInputDisplay(
            name: "Bash",
            input: .object(["command": .string("ls -la | head")])
        )
        XCTAssertEqual(bash?.text, "ls -la | head")
        XCTAssertEqual(bash?.language, "sh")

        let read = ClaudeEventDecoder.toolInputDisplay(
            name: "Read",
            input: .object(["file_path": .string("/tmp/a.swift"), "limit": .number(50)])
        )
        XCTAssertEqual(read?.language, "json")
        XCTAssertEqual(read?.text, "{\n  \"file_path\": \"/tmp/a.swift\",\n  \"limit\": 50\n}")

        XCTAssertNil(ClaudeEventDecoder.toolInputDisplay(name: "Bash", input: .object([:])),
                     "un input vide (content_block_start) ne doit rien afficher")
    }

    func testDecodesResultEvent() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":2300,"num_turns":3,"result":"Voilà !","session_id":"def-456","total_cost_usd":0.0042,"usage":{"input_tokens":10,"output_tokens":20}}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.completed(sessionID: "def-456",
                        meta: TurnMeta(costUSD: 0.0042, durationMS: 2300, numTurns: 3),
                        isError: false,
                        errorText: nil)]
        )
    }

    func testDecodesStreamEventTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bon"}},"session_id":"abc","uuid":"u1"}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: line), [.textDelta("Bon")])
    }

    func testDecodesStreamEventMessageStartAndToolStart() {
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01","role":"assistant","content":[]}},"session_id":"abc"}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: start), [.messageStarted(id: "msg_01")])

        let tool = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_02","name":"Bash","input":{}}},"session_id":"abc"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: tool),
            [.toolStarted(index: 1, id: "toolu_02", name: "Bash", detail: nil)]
        )
    }

    func testDecodesLiveStreamingEvents() {
        // L'input d'un outil streamé fragment par fragment (affichage direct).
        let inputDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ls"}},"session_id":"abc"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: inputDelta),
            [.toolInputDelta(index: 1, partialJSON: #"{"command": "ls"#)]
        )

        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Je réfléchis"}},"session_id":"abc"}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: thinking), [.thinkingDelta("Je réfléchis")])

        let blockStop = #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"session_id":"abc"}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: blockStop), [.blockFinished(index: 1)])

        let messageStop = #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"abc"}"#
        XCTAssertEqual(ClaudeEventDecoder.decode(line: messageStop), [.messageStopped])
    }

    func testMapsThinkingBlocks() {
        let line = #"{"type":"assistant","message":{"id":"msg_03","role":"assistant","content":[{"type":"thinking","thinking":"Voyons voir…"},{"type":"text","text":"OK"}]},"session_id":"abc"}"#
        XCTAssertEqual(
            ClaudeEventDecoder.decode(line: line),
            [.assistantMessage(id: "msg_03", segments: [.thinking("Voyons voir…"), .text("OK")])]
        )
    }

    func testWriteInputDisplayShowsFileContentWithLanguage() {
        let write = ClaudeEventDecoder.toolInputDisplay(
            name: "Write",
            input: .object([
                "file_path": .string("/tmp/App.swift"),
                "content": .string("let x = 1\n"),
            ])
        )
        XCTAssertEqual(write?.text, "let x = 1\n")
        XCTAssertEqual(write?.language, "swift")
    }

    func testIgnoresUnknownAndMalformedLines() {
        XCTAssertEqual(ClaudeEventDecoder.decode(line: ""), [])
        XCTAssertEqual(ClaudeEventDecoder.decode(line: "pas du json"), [])
        XCTAssertEqual(ClaudeEventDecoder.decode(line: #"{"type":"martien","x":1}"#), [])
    }
}

// MARK: - PartialJSON (réparation des inputs streamés)

final class PartialJSONTests: XCTestCase {

    func testParsesCompleteJSON() {
        let value = PartialJSON.parse(#"{"command": "ls -la"}"#)
        XCTAssertEqual(value?["command"]?.stringValue, "ls -la")
    }

    func testClosesUnterminatedString() {
        let value = PartialJSON.parse(#"{"command": "git sta"#)
        XCTAssertEqual(value?["command"]?.stringValue, "git sta")
    }

    func testClosesNestedBracketsAndPreservesEscapes() {
        let value = PartialJSON.parse(#"{"content": "ligne 1\nligne 2 \"citée"#)
        XCTAssertEqual(value?["content"]?.stringValue, "ligne 1\nligne 2 \"citée")
    }

    func testTruncatesIncompleteEscapeSequence() {
        // Le flux peut couper en plein milieu d'un \uXXXX : on tronque avant.
        let value = PartialJSON.parse(#"{"content": "fl\u00e"#)
        XCTAssertEqual(value?["content"]?.stringValue, "fl")
    }

    func testDropsDanglingKeyAndComma() {
        XCTAssertEqual(
            PartialJSON.parse(#"{"file_path": "/tmp/a.txt", "content":"#)?["file_path"]?.stringValue,
            "/tmp/a.txt"
        )
        XCTAssertEqual(
            PartialJSON.parse(#"{"file_path": "/tmp/a.txt","#)?["file_path"]?.stringValue,
            "/tmp/a.txt"
        )
    }

    func testRejectsNonObjectFragments() {
        XCTAssertNil(PartialJSON.parse(""))
        XCTAssertNil(PartialJSON.parse("pas du json"))
    }
}

// MARK: - Historique JSONL

final class SessionHistoryTests: XCTestCase {

    func testEncodedDirectoryNameMatchesClaudeCodeConvention() {
        let url = URL(fileURLWithPath: "/Users/max/Desktop/Claude code test")
        XCTAssertEqual(
            SessionHistoryService.encodedDirectoryName(for: url),
            "-Users-max-Desktop-Claude-code-test"
        )
    }

    func testLoadMessagesFromJSONLFixture() throws {
        let fixture = """
        {"parentUuid":null,"isSidechain":false,"cwd":"/tmp","sessionId":"s1","type":"user","message":{"role":"user","content":"Salut Claude"},"uuid":"u-1","timestamp":"2026-07-14T10:00:00.000Z"}
        {"parentUuid":"u-1","isSidechain":false,"sessionId":"s1","type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Salut !"}]},"uuid":"u-2","timestamp":"2026-07-14T10:00:02.000Z"}
        {"parentUuid":"u-2","isSidechain":false,"sessionId":"s1","type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},"uuid":"u-3","timestamp":"2026-07-14T10:00:03.000Z"}
        {"parentUuid":"u-3","isSidechain":false,"sessionId":"s1","type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]},"uuid":"u-4","timestamp":"2026-07-14T10:00:04.000Z"}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-companion-test-\(UUID().uuidString).jsonl")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = SessionHistoryService.loadMessages(from: url)
        XCTAssertEqual(messages.count, 2, "attendu : 1 user + 1 assistant fusionné, obtenu \(messages)")

        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].segments, [.text("Salut Claude")])

        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].id, "msg_1")
        XCTAssertEqual(messages[1].segments.count, 2, "les deux lignes msg_1 doivent fusionner")
        if case .tool(let call) = messages[1].segments[1] {
            XCTAssertEqual(call.status, .done, "dans l'historique, les outils sont terminés")
            XCTAssertEqual(call.detail, "ls")
            XCTAssertEqual(call.output, "a.txt", "la sortie du tool_result doit être rattachée")
            XCTAssertEqual(call.inputDisplay, "ls", "l'entrée Bash doit être affichable")
        } else {
            XCTFail("second segment attendu : tool_use")
        }
    }
}

// MARK: - SyntaxHighlighter (fumée)

final class SyntaxHighlighterTests: XCTestCase {

    func testHighlightPreservesTextExactly() {
        let code = "// commentaire\nlet url = \"https://example.com\" // fin\nfunc f() -> Int { return 0x1F }"
        let highlighted = SyntaxHighlighter.highlight(code, language: "swift")
        XCTAssertEqual(String(highlighted.characters), code,
                       "la coloration ne doit jamais altérer le texte")
    }

    func testEmptyCode() {
        XCTAssertEqual(String(SyntaxHighlighter.highlight("", language: "swift").characters), "")
    }
}

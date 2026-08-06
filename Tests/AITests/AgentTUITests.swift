import XCTest
@testable import AI
@testable import AITUI
import AITesting

final class MarkdownTerminalRendererTests: XCTestCase {

    private func plain(_ markdown: String, width: Int = 40) -> [String] {
        MarkdownTerminalRenderer.render(markdown, width: width).map(\.plainText)
    }

    func testHeadingsBulletsAndRules() {
        let lines = plain("# Title\n\n- first\n- second\n\n---")
        XCTAssertEqual(lines[0], "# Title")
        XCTAssertEqual(lines[2], "• first")
        XCTAssertEqual(lines[3], "• second")
        XCTAssertEqual(lines.last, String(repeating: "─", count: 40))
    }

    func testOrderedListsKeepNumbering() {
        let lines = plain("1. one\n2. two")
        XCTAssertEqual(lines, ["1. one", "2. two"])
    }

    func testParagraphWrapsAtWidthWithoutSplittingWords() {
        let lines = plain("alpha bravo charlie delta echo foxtrot golf", width: 20)
        for line in lines {
            XCTAssertLessThanOrEqual(TerminalText.width(line), 20, line)
        }
        XCTAssertEqual(lines.joined(separator: " "), "alpha bravo charlie delta echo foxtrot golf")
    }

    func testListContinuationLinesAreIndentedUnderTheMarker() {
        let lines = plain("- alpha bravo charlie delta echo foxtrot", width: 18)
        XCTAssertTrue(lines[0].hasPrefix("• "), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("  "), lines[1])
        XCTAssertFalse(lines[1].hasPrefix("  •"), lines[1])
    }

    func testCodeFenceKeepsContentVerbatimBehindABar() {
        let lines = plain("```swift\nlet x = 1\n\nlet y = 2\n```")
        XCTAssertEqual(lines, ["│ let x = 1", "│ ", "│ let y = 2"])
    }

    func testInlineStylesAreAppliedAndMarkersRemoved() {
        let runs = MarkdownTerminalRenderer.inline(
            "**bold** and `code` and [docs](https://example.com)", theme: .default
        )
        let text = runs.map(\.text).joined()
        XCTAssertEqual(text, "bold and code and docs (https://example.com)")
        XCTAssertTrue(runs.contains { $0.text == "bold" && $0.style.bold })
        XCTAssertTrue(runs.contains { $0.text == "code" && $0.style.color == .yellow })
        XCTAssertTrue(runs.contains { $0.text == "docs" && $0.style.underline })
    }

    func testBlockquotesArePrefixed() {
        XCTAssertEqual(plain("> quoted"), ["│ quoted"])
    }

    func testStyledOutputCarriesANSIOnlyWhenEnabled() {
        let line = StyledLine("hi", style: TerminalStyle(color: .red, bold: true))
        XCTAssertEqual(line.render(styled: false), "hi")
        XCTAssertEqual(line.render(styled: true), "\u{1B}[1;31mhi\u{1B}[0m")
    }

    func testWideCharactersCountAsTwoColumns() {
        XCTAssertEqual(TerminalText.width("日本語"), 6)
        XCTAssertEqual(TerminalText.width("abc"), 3)
        XCTAssertEqual(TerminalText.truncate("abcdef", to: 4), "abc…")
    }
}

final class TerminalKeyDecoderTests: XCTestCase {

    private func keys(_ bytes: [UInt8]) -> [TerminalKey] {
        var decoder = TerminalKeyDecoder()
        return decoder.feed(bytes)
    }

    func testArrowsAndPagingSequences() {
        XCTAssertEqual(keys([0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x43]), [.right])
        XCTAssertEqual(keys([0x1B, 0x5B, 0x44]), [.left])
        XCTAssertEqual(keys(Array("\u{1B}[5~".utf8)), [.pageUp])
        XCTAssertEqual(keys(Array("\u{1B}[6~".utf8)), [.pageDown])
    }

    func testControlKeys() {
        XCTAssertEqual(keys([0x03]), [.interrupt])
        XCTAssertEqual(keys([0x0C]), [.repaint])
        XCTAssertEqual(keys([0x15]), [.clearLine])
        XCTAssertEqual(keys([0x17]), [.deleteWord])
        XCTAssertEqual(keys([0x0D]), [.enter])
        XCTAssertEqual(keys([0x7F]), [.backspace])
    }

    func testPrintableAndMultibyteCharacters() {
        XCTAssertEqual(keys(Array("hi".utf8)), [.character("h"), .character("i")])
        XCTAssertEqual(keys(Array("é".utf8)), [.character("é")])
    }

    func testSplitEscapeSequenceIsBufferedUntilComplete() {
        var decoder = TerminalKeyDecoder()
        XCTAssertEqual(decoder.feed([0x1B]), [])
        XCTAssertTrue(decoder.hasPendingEscape)
        XCTAssertEqual(decoder.feed([0x5B]), [])
        XCTAssertEqual(decoder.feed([0x41]), [.up])
        XCTAssertFalse(decoder.hasPendingEscape)
    }

    func testLoneEscapeFlushesAsEscapeKey() {
        var decoder = TerminalKeyDecoder()
        XCTAssertEqual(decoder.feed([0x1B]), [])
        XCTAssertEqual(decoder.flushEscape(), [.escape])
        XCTAssertFalse(decoder.hasPendingEscape)
    }

    func testSplitMultibyteCharacterIsBuffered() {
        var decoder = TerminalKeyDecoder()
        let bytes = Array("é".utf8)
        XCTAssertEqual(decoder.feed([bytes[0]]), [])
        XCTAssertEqual(decoder.feed([bytes[1]]), [.character("é")])
    }
}

final class TranscriptRendererTests: XCTestCase {

    private func toolMessage(state: UIToolState, output: JSONValue? = nil) -> UIMessage {
        UIMessage(id: "m1", role: .assistant, parts: [
            .tool(ToolUIPart(
                toolName: "weather",
                toolCallID: "c1",
                state: state,
                input: ["location": "San Francisco"],
                output: output,
                approval: state == .approvalRequested ? ToolApproval(id: "a1") : nil
            ))
        ])
    }

    private func plain(
        _ messages: [UIMessage], options: TerminalTranscriptOptions
    ) -> [String] {
        TranscriptRenderer.lines(for: messages, width: 60, options: options).map(\.plainText)
    }

    func testUserMessagesGetAPromptPrefix() {
        let lines = plain([.user("hello there")], options: TerminalTranscriptOptions())
        XCTAssertEqual(lines.first, "› hello there")
    }

    func testToolCardShowsStateAndInputWhenExpanded() {
        let lines = plain(
            [toolMessage(state: .outputAvailable, output: ["temperature": 72])],
            options: TerminalTranscriptOptions(tools: .full)
        )
        XCTAssertTrue(lines[0].hasPrefix("✓ weather"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("input:") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("\"temperature\"") }, "\(lines)")
    }

    func testCollapsedToolsShowOnlyTheHeader() {
        let lines = plain(
            [toolMessage(state: .outputAvailable, output: ["temperature": 72])],
            options: TerminalTranscriptOptions(tools: .collapsed)
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("output:"))
    }

    func testHiddenToolsAreOmitted() {
        let lines = plain(
            [toolMessage(state: .outputAvailable)],
            options: TerminalTranscriptOptions(tools: .hidden)
        )
        XCTAssertTrue(lines.isEmpty, "\(lines)")
    }

    func testAutoCollapsedExpandsOnlyTheLatestSection() {
        let messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "weather", toolCallID: "c1",
                    state: .outputAvailable, input: ["location": "SF"], output: ["t": 72]
                )),
                .text(TextUIPart(text: "It is 72 degrees.", state: .done))
            ])
        ]
        let lines = plain(messages, options: TerminalTranscriptOptions(tools: .autoCollapsed))
        XCTAssertFalse(lines.contains { $0.contains("output:") }, "\(lines)")

        let toolOnly = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "weather", toolCallID: "c1",
                    state: .outputAvailable, input: ["location": "SF"], output: ["t": 72]
                ))
            ])
        ]
        let expanded = plain(toolOnly, options: TerminalTranscriptOptions(tools: .autoCollapsed))
        XCTAssertTrue(expanded.contains { $0.contains("output:") }, "\(expanded)")
    }

    func testApprovalRequestsAlwaysExpandEvenWhenCollapsed() {
        let lines = plain(
            [toolMessage(state: .approvalRequested)],
            options: TerminalTranscriptOptions(tools: .collapsed)
        )
        XCTAssertTrue(lines[0].hasPrefix("? weather"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("San Francisco") }, "\(lines)")
    }

    func testReasoningModesControlVisibility() {
        let message = UIMessage(id: "m1", role: .assistant, parts: [
            .reasoning(ReasoningUIPart(text: "thinking about it", state: .done)),
            .text(TextUIPart(text: "answer", state: .done))
        ])
        let hidden = plain([message], options: TerminalTranscriptOptions(reasoning: .hidden))
        XCTAssertFalse(hidden.contains { $0.contains("thinking about it") })

        let full = plain([message], options: TerminalTranscriptOptions(reasoning: .full))
        XCTAssertTrue(full.contains { $0.contains("Reasoning") })
        XCTAssertTrue(full.contains { $0.contains("thinking about it") })
    }
}

final class AgentTUIModelTests: XCTestCase {

    func testInputEditingAndCursorMovement() {
        var model = AgentTUIModel()
        for character in "hello world" { model.insert(character) }
        XCTAssertEqual(model.input, "hello world")

        model.deleteWord()
        XCTAssertEqual(model.input, "hello ")

        model.moveCursorToStart()
        model.insert("!")
        XCTAssertEqual(model.input, "!hello ")
        XCTAssertEqual(model.cursor, 1)

        model.moveCursorToEnd()
        model.deleteBackward()
        XCTAssertEqual(model.input, "!hello")

        XCTAssertEqual(model.takeInput(), "!hello")
        XCTAssertEqual(model.input, "")
        XCTAssertNil(model.takeInput())
    }

    func testScrollIsClampedToContent() {
        var model = AgentTUIModel()
        model.scroll(by: 50, viewportHeight: 10, contentHeight: 20)
        XCTAssertEqual(model.scrollOffset, 10)
        model.scroll(by: -50, viewportHeight: 10, contentHeight: 20)
        XCTAssertEqual(model.scrollOffset, 0)
    }

    func testPendingApprovalAndResponse() {
        var model = AgentTUIModel()
        model.messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "weather", toolCallID: "c1",
                    state: .approvalRequested, approval: ToolApproval(id: "a1")
                ))
            ])
        ]
        XCTAssertEqual(model.pendingApproval?.approvalID, "a1")
        XCTAssertEqual(model.pendingApproval?.toolName, "weather")

        XCTAssertTrue(model.respondToApproval(approvalID: "a1", approved: true))
        XCTAssertNil(model.pendingApproval)
        guard case .tool(let tool)? = model.messages[0].parts.first else {
            return XCTFail("expected a tool part")
        }
        XCTAssertEqual(tool.state, .approvalResponded)
        XCTAssertEqual(tool.approval?.approved, true)
    }

    func testMultipleApprovalsResolveOnlyWhenAllAnswered() {
        var model = AgentTUIModel()
        model.messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "a", toolCallID: "c1",
                    state: .approvalRequested, approval: ToolApproval(id: "a1")
                )),
                .tool(ToolUIPart(
                    toolName: "b", toolCallID: "c2",
                    state: .approvalRequested, approval: ToolApproval(id: "a2")
                ))
            ])
        ]
        XCTAssertFalse(model.respondToApproval(approvalID: "a1", approved: true))
        XCTAssertEqual(model.pendingApproval?.approvalID, "a2")
        XCTAssertTrue(model.respondToApproval(approvalID: "a2", approved: false))
    }

    func testStatisticsAndContextFormatting() {
        var model = AgentTUIModel(responseStatistics: .outputTokenCount, contextSize: 200_000)
        model.usage = TokenUsageSummary(inputTokens: 1_000, outputTokens: 500)
        XCTAssertEqual(model.statistics, "500 output tokens")
        XCTAssertEqual(model.contextUsage, "1.5k/200k ctx (1%)")

        model.responseStatistics = .outputTokensPerSecond
        model.responseDuration = 2
        XCTAssertEqual(model.statistics, "250.0 tok/s")
    }

    func testProvidersThatReportNoTokensShowNoStatistics() {
        var model = AgentTUIModel(contextSize: 8_192)
        model.usage = TokenUsageSummary(inputTokens: 0, outputTokens: 0)
        model.responseDuration = 1
        XCTAssertNil(model.statistics)
        XCTAssertNil(model.contextUsage)
    }

    func testUsageIsReadFromMessageMetadata() {
        let metadata = JSONValue.object(["usage": .object([
            "inputTokens": .number(3), "outputTokens": .number(7), "totalTokens": .number(10)
        ])])
        let usage = TokenUsageSummary.from(metadata: metadata)
        XCTAssertEqual(usage?.inputTokens, 3)
        XCTAssertEqual(usage?.outputTokens, 7)
        XCTAssertEqual(usage?.totalTokens, 10)
        XCTAssertNil(TokenUsageSummary.from(metadata: .object([:])))
    }
}

final class AgentTUIRendererTests: XCTestCase {

    private let size = TerminalSize(rows: 12, columns: 50)

    func testFrameFillsTheTerminalAndPinsInputToTheBottom() {
        var model = AgentTUIModel(title: "Weather Agent")
        model.messages = [.user("hi"), .assistant("hello")]
        let frame = AgentTUIRenderer.frame(model: model, size: size, styled: false)

        XCTAssertEqual(frame.rows.count, size.rows)
        XCTAssertEqual(frame.cursorRow, size.rows)
        XCTAssertEqual(frame.cursorColumn, 3)
        XCTAssertTrue(frame.rows.last?.hasPrefix("› ") == true, frame.rows.last ?? "")
        XCTAssertTrue(frame.rows[size.rows - 3].hasPrefix("─"), frame.rows[size.rows - 3])
        XCTAssertTrue(frame.rows[size.rows - 2].contains("Weather Agent"))
        for row in frame.rows {
            XCTAssertLessThanOrEqual(TerminalText.width(row), size.columns, row)
        }
    }

    func testStatusLineShowsStreamingStateAndStatistics() {
        var model = AgentTUIModel(title: "Agent", responseStatistics: .outputTokenCount)
        model.messages = [.user("hi")]
        model.status = .streaming
        model.usage = TokenUsageSummary(inputTokens: 10, outputTokens: 4)
        let frame = AgentTUIRenderer.frame(model: model, size: size, styled: false)
        let status = frame.rows[size.rows - 2]
        XCTAssertTrue(status.contains("streaming"), status)
        XCTAssertTrue(status.contains("4 output tokens"), status)
    }

    func testApprovalPromptTakesAnExtraRowAboveTheInput() {
        var model = AgentTUIModel()
        model.messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "weather", toolCallID: "c1",
                    state: .approvalRequested, approval: ToolApproval(id: "a1")
                ))
            ])
        ]
        let frame = AgentTUIRenderer.frame(model: model, size: size, styled: false)
        XCTAssertEqual(frame.rows.count, size.rows)
        let prompt = frame.rows[size.rows - 2]
        XCTAssertTrue(prompt.contains("Run tool weather?"), prompt)
        XCTAssertTrue(prompt.contains("y approve"), prompt)
    }

    func testScrollingMovesTheVisibleWindowUp() {
        var model = AgentTUIModel()
        model.messages = (0..<40).map { UIMessage.assistant("line \($0)") }
        let bottom = AgentTUIRenderer.frame(model: model, size: size, styled: false)
        model.scrollOffset = 5
        let scrolled = AgentTUIRenderer.frame(model: model, size: size, styled: false)
        XCTAssertNotEqual(bottom.rows[0], scrolled.rows[0])
        XCTAssertTrue(scrolled.rows[size.rows - 2].contains("scrolled +5"))
    }

    func testEmptyTranscriptShowsTheTitleHint() {
        let model = AgentTUIModel(title: "Assistant")
        let frame = AgentTUIRenderer.frame(model: model, size: size, styled: false)
        XCTAssertTrue(frame.rows[0].contains("Assistant"))
        XCTAssertTrue(frame.rows[2].contains("Type a message"))
    }
}

final class AgentChatTransportTests: XCTestCase {

    func testTransportStreamsTextAndReportsUsageMetadata() async throws {
        let model = MockLanguageModel(parts: [
            .textDelta("Hello"),
            .textDelta(" world"),
            .finish(reason: .stop, usage: Usage(inputTokens: 11, outputTokens: 4))
        ])
        let transport = AgentChatTransport(agent: Agent(model: model, instructions: "be nice"))
        let chunks = try await transport.sendMessages(
            ChatRequest(chatID: "chat-1", messages: [.user("hi")])
        )

        var reducer = UIMessageReducer()
        for try await chunk in chunks { reducer.apply(chunk) }

        XCTAssertEqual(reducer.message.text, "Hello world")
        let usage = TokenUsageSummary.from(metadata: reducer.message.metadata)
        XCTAssertEqual(usage?.outputTokens, 4)
        XCTAssertEqual(usage?.totalTokens, 15)
    }

    func testTransportSurfacesToolApprovalRequests() async throws {
        let weather = Tool(
            name: "weather",
            description: "Get the weather",
            parameters: ["type": "object"],
            needsApproval: true
        ) { _ in ["temperature": 72] }

        let model = MockLanguageModel(parts: [
            .toolCall(ToolCall(id: "c1", name: "weather", arguments: ["location": "SF"])),
            .finish(reason: .toolCalls, usage: Usage(inputTokens: 5, outputTokens: 2))
        ])
        let transport = AgentChatTransport(agent: Agent(model: model, tools: [weather]))
        let chunks = try await transport.sendMessages(
            ChatRequest(chatID: "chat-1", messages: [.user("weather in SF?")])
        )

        var reducer = UIMessageReducer()
        for try await chunk in chunks { reducer.apply(chunk) }

        var state = AgentTUIModel()
        state.messages = [.user("weather in SF?"), reducer.message]
        let approval = try XCTUnwrap(state.pendingApproval)
        XCTAssertEqual(approval.toolName, "weather")
        XCTAssertTrue(state.respondToApproval(approvalID: approval.approvalID, approved: true))

        let resumed = convertToModelMessages(state.messages)
        let responses = resumed.flatMap(\.content).filter {
            if case .toolApprovalResponse = $0 { return true }
            return false
        }
        XCTAssertEqual(responses.count, 1)
    }
}

final class TerminalEscapeInjectionTests: XCTestCase {

    func testControlCharactersAreStrippedFromRuns() {
        let hostile = "read_file\u{1B}[2J\u{1B}[1;1Happroved: rm -rf ~"
        let run = StyledRun(hostile)
        XCTAssertFalse(run.text.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertTrue(run.text.contains("read_file"), "visible text is preserved")
    }

    func testEightBitCSIAndOSCAreStripped() {
        let run = StyledRun("a\u{9B}2Jb\u{9D}0;titlec")
        XCTAssertFalse(run.text.unicodeScalars.contains { (0x80...0x9F).contains($0.value) })
    }

    func testTabAndNewlineSurvive() {
        XCTAssertEqual(StyledRun("a\tb\nc").text, "a\tb\nc")
    }

    func testRenderedLineCarriesNoEscapesFromUntrustedText() {
        let line = StyledLine("\u{1B}]0;swallow", style: .plain)
        XCTAssertFalse(line.render(styled: false).unicodeScalars.contains { $0.value == 0x1B })
    }

    func testControlCharactersHaveNoWidth() {
        XCTAssertEqual(TerminalText.width("\u{1B}"), 0)
        XCTAssertEqual(TerminalText.width("ab"), 2)
    }
}

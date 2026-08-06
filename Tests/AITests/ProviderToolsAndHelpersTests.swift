import XCTest
@testable import AI
import AITesting

final class NewProviderDefinedToolsTests: XCTestCase {

    private func args(_ tool: ProviderDefinedTool) -> JSONValue { tool.args }

    func testOpenAIImageGenerationWireShape() {
        let tool = OpenAIModel.Tools.imageGeneration(
            background: "transparent",
            model: "gpt-image-2",
            outputCompression: 80,
            outputFormat: "webp",
            partialImages: 2,
            quality: "high",
            size: "1024x1536"
        )
        XCTAssertEqual(tool.id, "openai.image_generation")
        XCTAssertEqual(args(tool)["type"], "image_generation")
        XCTAssertEqual(args(tool)["background"], "transparent")
        XCTAssertEqual(args(tool)["model"], "gpt-image-2")
        XCTAssertEqual(args(tool)["output_compression"], .number(80))
        XCTAssertEqual(args(tool)["output_format"], "webp")
        XCTAssertEqual(args(tool)["partial_images"], .number(2))
        XCTAssertEqual(args(tool)["quality"], "high")
        XCTAssertEqual(args(tool)["size"], "1024x1536")
    }

    func testOpenAIShellFamilyWireShapes() {
        XCTAssertEqual(
            args(OpenAIModel.Tools.localShell()), .object(["type": "local_shell"])
        )
        XCTAssertEqual(
            args(OpenAIModel.Tools.applyPatch()), .object(["type": "apply_patch"])
        )
        XCTAssertEqual(
            args(OpenAIModel.Tools.programmaticToolCalling()),
            .object(["type": "programmatic_tool_calling"])
        )

        let shell = OpenAIModel.Tools.shell(environment: ["type": "container"])
        XCTAssertEqual(args(shell)["type"], "shell")
        XCTAssertEqual(args(shell)["environment"]?["type"], "container")
        XCTAssertEqual(shell.id, "openai.shell")
    }

    func testOpenAIToolSearchAndCustomTool() {
        let search = OpenAIModel.Tools.toolSearch(execution: "server", description: "find tools")
        XCTAssertEqual(args(search)["type"], "tool_search")
        XCTAssertEqual(args(search)["execution"], "server")
        XCTAssertEqual(args(search)["description"], "find tools")

        let custom = OpenAIModel.Tools.customTool(
            name: "sql", description: "Runs SQL", format: ["type": "grammar"]
        )
        XCTAssertEqual(custom.id, "openai.custom")
        XCTAssertEqual(args(custom)["type"], "custom")
        XCTAssertEqual(args(custom)["name"], "sql")
        XCTAssertEqual(args(custom)["format"]?["type"], "grammar")
    }

    func testOpenAIHostedMCPTool() {
        let tool = OpenAIModel.Tools.mcpServer(
            serverLabel: "docs",
            serverURL: "https://example.com/mcp",
            allowedTools: ["search"],
            headers: ["x-key": "value"]
        )
        XCTAssertEqual(tool.id, "openai.mcp")
        XCTAssertEqual(args(tool)["type"], "mcp")
        XCTAssertEqual(args(tool)["server_label"], "docs")
        XCTAssertEqual(args(tool)["server_url"], "https://example.com/mcp")
        XCTAssertEqual(args(tool)["allowed_tools"], .array(["search"]))
        XCTAssertEqual(args(tool)["headers"]?["x-key"], "value")
        XCTAssertEqual(args(tool)["require_approval"], "never")
    }

    func testAnthropicAdvisorCarriesItsBetaHeader() {
        let tool = AnthropicModel.Tools.advisor(model: "claude-haiku-4-5", maxUses: 3)
        XCTAssertEqual(tool.id, "anthropic.advisor_20260301")
        XCTAssertEqual(args(tool)["type"], "advisor_20260301")
        XCTAssertEqual(args(tool)["name"], "advisor")
        XCTAssertEqual(args(tool)["model"], "claude-haiku-4-5")
        XCTAssertEqual(args(tool)["max_uses"], .number(3))

        let request = LanguageModelRequest(messages: [.user("hi")], tools: [tool])
        XCTAssertTrue(
            AnthropicModel.betaFlags(for: request).contains("advisor-tool-2026-03-01"),
            "\(AnthropicModel.betaFlags(for: request))"
        )
    }

    func testAnthropicToolSearchVariants() {
        let bm25 = AnthropicModel.Tools.toolSearchBm25()
        XCTAssertEqual(bm25.id, "anthropic.tool_search_tool_bm25_20251119")
        XCTAssertEqual(args(bm25)["type"], "tool_search_tool_bm25_20251119")
        XCTAssertEqual(args(bm25)["name"], "tool_search_tool_bm25")

        let regex = AnthropicModel.Tools.toolSearchRegex()
        XCTAssertEqual(regex.id, "anthropic.tool_search_tool_regex_20251119")
        XCTAssertEqual(args(regex)["type"], "tool_search_tool_regex_20251119")

        let pinned = AnthropicModel.Tools.toolSearchBm25(version: "tool_search_tool_bm25_20260401")
        XCTAssertEqual(args(pinned)["type"], "tool_search_tool_bm25_20260401")
    }

    func testAnthropicNewerToolVersionsMapToBetas() {
        let request = LanguageModelRequest(messages: [.user("hi")], tools: [
            AnthropicModel.Tools.codeExecution(version: "code_execution_20260120"),
            AnthropicModel.Tools.computer(
                displayWidthPx: 1024, displayHeightPx: 768, version: "computer_20251124"
            )
        ])
        let betas = AnthropicModel.betaFlags(for: request)
        XCTAssertTrue(betas.contains("code-execution-web-tools-2026-02-09"), "\(betas)")
        XCTAssertTrue(betas.contains("computer-use-2025-11-24"), "\(betas)")
    }

    func testGoogleVertexRagStore() {
        let tool = GoogleModel.Tools.vertexRagStore(
            ragCorpus: "projects/p/locations/l/ragCorpora/1", topK: 5
        )
        XCTAssertEqual(tool.id, "google.vertex_rag_store")
        let store = args(tool)["retrieval"]?["vertex_rag_store"]
        XCTAssertEqual(
            store?["rag_resources"]?["rag_corpus"], "projects/p/locations/l/ragCorpora/1"
        )
        XCTAssertEqual(store?["similarity_top_k"], .number(5))
    }
}

final class UIHelperTests: XCTestCase {

    func testValidateUIMessagesRejectsIncompleteToolParts() {
        let missingOutput = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(toolName: "t", toolCallID: "c1", state: .outputAvailable))
            ])
        ]
        XCTAssertThrowsError(try validateUIMessages(missingOutput))
        XCTAssertThrowsError(try validateUIMessages([
            UIMessage(id: "m2", role: .assistant, parts: [
                .tool(ToolUIPart(toolName: "t", toolCallID: "c1", state: .approvalRequested))
            ])
        ]))

        let valid = [
            UIMessage(id: "m3", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "t", toolCallID: "c1", state: .outputAvailable, output: .string("ok")
                ))
            ])
        ]
        XCTAssertEqual(try validateUIMessages(valid).count, 1)
        XCTAssertNoThrow(try safeValidateUIMessages(valid).get())
        if case .success = safeValidateUIMessages(missingOutput) {
            XCTFail("expected a validation failure")
        }
    }

    func testEmptyAssistantPartsRemainLoadable() {
        let persisted = [UIMessage(id: "m1", role: .assistant, parts: [])]
        XCTAssertNoThrow(try validateUIMessages(persisted))
    }

    func testLastAssistantMessageCompletionPredicates() {
        let complete = [
            UIMessage.user("hi"),
            UIMessage(id: "m2", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "t", toolCallID: "c1", state: .outputAvailable, output: .null
                ))
            ])
        ]
        XCTAssertTrue(lastAssistantMessageIsCompleteWithToolCalls(complete))

        let pending = [
            UIMessage(id: "m2", role: .assistant, parts: [
                .tool(ToolUIPart(toolName: "t", toolCallID: "c1", state: .inputAvailable))
            ])
        ]
        XCTAssertFalse(lastAssistantMessageIsCompleteWithToolCalls(pending))
        XCTAssertFalse(lastAssistantMessageIsCompleteWithToolCalls([UIMessage.user("hi")]))

        let answered = [
            UIMessage(id: "m2", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "t", toolCallID: "c1", state: .approvalResponded,
                    approval: ToolApproval(id: "a1", approved: true)
                ))
            ])
        ]
        XCTAssertTrue(lastAssistantMessageIsCompleteWithApprovalResponses(answered))

        let awaiting = [
            UIMessage(id: "m2", role: .assistant, parts: [
                .tool(ToolUIPart(
                    toolName: "t", toolCallID: "c1", state: .approvalRequested,
                    approval: ToolApproval(id: "a1")
                ))
            ])
        ]
        XCTAssertFalse(lastAssistantMessageIsCompleteWithApprovalResponses(awaiting))
    }

    func testConsumeStreamDrainsWithoutRendering() async {
        let model = MockLanguageModel(parts: [
            .textDelta("a"), .textDelta("b"), .finish(reason: .stop, usage: Usage())
        ])
        let result = streamText(model: model, prompt: "hi")
        await result.consumeStream()
        XCTAssertEqual(model.requests.count, 1)
    }

    func testConsumeStreamReportsErrors() async {
        let failing = AsyncThrowingStream<UIMessageChunk, Error> { continuation in
            continuation.finish(throwing: AIError.transport("boom"))
        }
        let seen = ErrorBox()
        await consumeStream(failing) { error in await seen.set("\(error)") }
        let message = await seen.value
        XCTAssertTrue(message.contains("boom"), message)
    }

    func testTextStreamTransportWrapsPlainTextLines() async throws {
        let transport = TextStreamChatTransport(api: URL(string: "https://example.com/api")!)
        XCTAssertEqual(transport.api.absoluteString, "https://example.com/api")
    }
}

private actor ErrorBox {
    private(set) var value = ""
    func set(_ text: String) { value = text }
}

final class UpstreamBehaviorFixTests: XCTestCase {

    func testRepeatedToolCallIDsKeepDistinctParts() {
        var reducer = UIMessageReducer()
        reducer.apply(.toolInputAvailable(toolCallID: "c1", toolName: "search", input: ["q": "a"]))
        reducer.apply(.toolOutputAvailable(toolCallID: "c1", output: ["hits": 1]))
        reducer.apply(.toolInputAvailable(toolCallID: "c1", toolName: "search", input: ["q": "b"]))
        reducer.apply(.toolOutputAvailable(toolCallID: "c1", output: ["hits": 2]))

        let toolParts = reducer.message.parts.compactMap { part -> ToolUIPart? in
            if case .tool(let tool) = part { return tool }
            return nil
        }
        XCTAssertEqual(toolParts.count, 2, "a reused tool call id must not overwrite the first part")
        XCTAssertEqual(toolParts[0].input?["q"], "a")
        XCTAssertEqual(toolParts[0].output?["hits"], .number(1))
        XCTAssertEqual(toolParts[1].input?["q"], "b")
        XCTAssertEqual(toolParts[1].output?["hits"], .number(2))
    }

    func testInFlightToolPartsStillUpdateInPlace() {
        var reducer = UIMessageReducer()
        reducer.apply(.toolInputStart(toolCallID: "c1", toolName: "search"))
        reducer.apply(.toolInputDelta(toolCallID: "c1", inputTextDelta: "{\"q\":"))
        reducer.apply(.toolInputAvailable(toolCallID: "c1", toolName: "search", input: ["q": "a"]))
        let toolParts = reducer.message.parts.filter {
            if case .tool = $0 { return true }
            return false
        }
        XCTAssertEqual(toolParts.count, 1)
    }

    func testCancellationDuringToolExecutionAbortsTheRun() async throws {
        let slow = Tool(
            name: "slow", description: "Sleeps.", parameters: ["type": "object"]
        ) { _ in
            try await Task.sleep(for: .seconds(10))
            return .string("never")
        }
        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "slow", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("after"), .finish(reason: .stop, usage: Usage())]
        ])

        let aborted = AbortFlag()
        let result = streamText(
            model: model, prompt: "go", tools: [slow],
            onAbort: { await aborted.mark() }
        )

        let consumer = Task {
            var parts: [TextStreamPart] = []
            for try await part in result.fullStream { parts.append(part) }
            return parts
        }
        try await Task.sleep(for: .milliseconds(120))
        consumer.cancel()
        _ = try? await consumer.value

        for _ in 0..<40 where await !aborted.value {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let didAbort = await aborted.value
        XCTAssertTrue(didAbort, "cancelling during tool execution must surface as an abort")
    }

    func testMP4AudioIsDetectedFromItsFtypBox() {
        var mp4 = Data([0, 0, 0, 0x20])
        mp4.append(contentsOf: Array("ftypM4A ".utf8))
        mp4.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(detectAudioMediaType(mp4), "audio/mp4")

        var wav = Data(Array("RIFF".utf8))
        wav.append(Data([0, 0, 0, 0]))
        wav.append(Data(Array("WAVEfmt ".utf8)))
        XCTAssertEqual(detectAudioMediaType(wav), "audio/wav")

        var ogg = Data(Array("OggS".utf8))
        ogg.append(Data(repeating: 0, count: 12))
        XCTAssertEqual(detectAudioMediaType(ogg), "audio/ogg")

        var mp3 = Data(Array("ID3".utf8))
        mp3.append(Data(repeating: 0, count: 12))
        XCTAssertEqual(detectAudioMediaType(mp3), "audio/mpeg")

        XCTAssertNil(detectAudioMediaType(Data(repeating: 0x41, count: 16)))
    }

    func testTranscribeUpgradesGenericMediaTypesFromTheBytes() async throws {
        var mp4 = Data([0, 0, 0, 0x20])
        mp4.append(contentsOf: Array("ftypM4A ".utf8))
        mp4.append(Data(repeating: 0, count: 8))

        let model = RecordingTranscriptionModel()
        _ = try await transcribe(
            model: model, audio: mp4, mediaType: "application/octet-stream"
        )
        let seen = await model.observed.mediaType
        XCTAssertEqual(seen, "audio/mp4")
    }
}

private actor AbortFlag {
    private(set) var value = false
    func mark() { value = true }
}

private struct RecordingTranscriptionModel: TranscriptionModel {
    let provider = "recording"
    let modelID = "recording"
    let observed = MediaTypeObserver()

    func transcribe(_ request: TranscriptionModelRequest) async throws -> TranscriptionModelResponse {
        await observed.record(request.mediaType)
        return TranscriptionModelResponse(text: "ok")
    }
}

private actor MediaTypeObserver {
    private(set) var mediaType = ""
    func record(_ value: String) { mediaType = value }
}

final class AudioResamplingTests: XCTestCase {

    func testDownsamplingHalvesTheSampleCount() {
        let input: [Float] = [0, 0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25]
        let output = resampleAudio(input, inputRate: 48_000, outputRate: 24_000)
        XCTAssertEqual(output.count, 4)
        XCTAssertEqual(output.first ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(output.last ?? 0, 0.25, accuracy: 0.0001)
    }

    func testUpsamplingInterpolatesBetweenSamples() {
        let output = resampleAudio([0, 1], inputRate: 8_000, outputRate: 16_000)
        XCTAssertEqual(output.count, 4)
        XCTAssertEqual(output[0], 0, accuracy: 0.0001)
        XCTAssertEqual(output[3], 1, accuracy: 0.0001)
        XCTAssertTrue(output[1] > 0 && output[1] < 1)
    }

    func testMatchingRatesAreAPassthrough() {
        let input: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(resampleAudio(input, inputRate: 24_000, outputRate: 24_000), input)
        XCTAssertEqual(resampleAudio([Float](), inputRate: 8_000, outputRate: 16_000), [])
    }

    func testPCM16RoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let encoded = encodePCM16(samples)
        XCTAssertEqual(encoded.count, samples.count * 2)
        let decoded = decodePCM16(encoded)
        XCTAssertEqual(decoded.count, samples.count)
        for (original, round) in zip(samples, decoded) {
            XCTAssertEqual(original, round, accuracy: 0.0001)
        }
    }

    func testDataResamplingChangesByteCount() {
        let samples = (0..<100).map { Float(sin(Double($0) / 10)) }
        let data = encodePCM16(samples)
        let resampled = resampleAudio(data, inputRate: 48_000, outputRate: 24_000)
        XCTAssertEqual(resampled.count, 100)
    }
}

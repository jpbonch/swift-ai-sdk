import XCTest
@testable import AI
import AITesting

final class PruneMessagesTests: XCTestCase {

    private func history() -> [Message] {
        [
            .user("first"),
            Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "c1", name: "search", arguments: ["q": "swift"]))
            ]),
            Message(role: .tool, content: [
                .toolResult(ToolResult(toolCallID: "c1", name: "search", output: ["hits": 3]))
            ]),
            Message(role: .assistant, content: [.text("found three")]),
            .user("second"),
            Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "c2", name: "search", arguments: ["q": "again"]))
            ]),
            Message(role: .tool, content: [
                .toolResult(ToolResult(toolCallID: "c2", name: "search", output: ["hits": 1]))
            ])
        ]
    }

    private func toolCallIDs(_ messages: [Message]) -> [String] {
        messages.flatMap(\.content).compactMap {
            if case .toolCall(let call) = $0 { return call.id }
            return nil
        }
    }

    private func toolResultIDs(_ messages: [Message]) -> [String] {
        messages.flatMap(\.content).compactMap {
            if case .toolResult(let result) = $0 { return result.toolCallID }
            return nil
        }
    }

    func testPruningAllToolCallsAlsoDropsTheirResults() {
        let pruned = pruneMessages(history(), toolCalls: .all)
        XCTAssertTrue(toolCallIDs(pruned).isEmpty)
        XCTAssertTrue(toolResultIDs(pruned).isEmpty)
        XCTAssertEqual(pruned.map(\.text), ["first", "found three", "second"])
    }

    func testBeforeLastMessagesKeepsRecentToolTraffic() {
        let pruned = pruneMessages(history(), toolCalls: .beforeLastMessages(3))
        XCTAssertEqual(toolCallIDs(pruned), ["c2"])
        XCTAssertEqual(toolResultIDs(pruned), ["c2"])
    }

    func testPruningIsScopedToNamedTools() {
        var messages = history()
        messages.append(Message(role: .assistant, content: [
            .toolCall(ToolCall(id: "c3", name: "weather", arguments: [:]))
        ]))
        messages.append(.user("third"))

        let pruned = pruneMessages(
            messages, toolCalls: .beforeLastMessages(1, tools: ["search"])
        )
        XCTAssertEqual(toolCallIDs(pruned), ["c3"])
    }

    func testEmptyMessagesCanBeKept() {
        let kept = pruneMessages(history(), toolCalls: .all, emptyMessages: .keep)
        XCTAssertEqual(kept.count, history().count)
        XCTAssertTrue(kept.contains { $0.content.isEmpty })
    }

    func testNoRulesLeavesHistoryUntouched() {
        XCTAssertEqual(pruneMessages(history()), history())
    }

    func testUIMessageReasoningPruning() {
        let messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .reasoning(ReasoningUIPart(text: "old thinking", state: .done)),
                .text(TextUIPart(text: "old answer", state: .done))
            ]),
            UIMessage(id: "m2", role: .user, parts: [.text(TextUIPart(text: "again"))]),
            UIMessage(id: "m3", role: .assistant, parts: [
                .reasoning(ReasoningUIPart(text: "fresh thinking", state: .done)),
                .text(TextUIPart(text: "fresh answer", state: .done))
            ])
        ]

        let pruned = pruneMessages(messages, reasoning: .beforeLastMessage)
        let reasoning = pruned.flatMap(\.parts).compactMap { part -> String? in
            if case .reasoning(let value) = part { return value.text }
            return nil
        }
        XCTAssertEqual(reasoning, ["fresh thinking"])
        XCTAssertEqual(pruned.count, 3)
    }

    func testUIMessagePruningDropsToolPartsAndEmptyMessages() {
        let messages = [
            UIMessage(id: "m1", role: .assistant, parts: [
                .tool(ToolUIPart(toolName: "search", toolCallID: "c1", state: .outputAvailable))
            ]),
            UIMessage(id: "m2", role: .assistant, parts: [.text(TextUIPart(text: "answer"))])
        ]
        let pruned = pruneMessages(messages, toolCalls: .all)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned[0].id, "m2")
    }
}

final class ModelMiddlewareTests: XCTestCase {

    func testExtractJsonStripsCodeFences() async throws {
        let model = MockLanguageModel(parts: [
            .textDelta("```json\n"),
            .textDelta("{\"city\":"),
            .textDelta("\"Paris\"}"),
            .textDelta("\n```"),
            .finish(reason: .stop, usage: Usage())
        ])
        let wrapped = wrapLanguageModel(model: model, middleware: [.extractJson()])
        let result = try await generateText(model: wrapped, prompt: "json please")
        XCTAssertEqual(result.text, "{\"city\":\"Paris\"}")
    }

    func testExtractJsonLeavesUnfencedTextAlone() async throws {
        let model = MockLanguageModel(parts: [
            .textDelta("{\"ok\":true}"),
            .finish(reason: .stop, usage: Usage())
        ])
        let wrapped = wrapLanguageModel(model: model, middleware: [.extractJson()])
        let result = try await generateText(model: wrapped, prompt: "json please")
        XCTAssertEqual(result.text, "{\"ok\":true}")
    }

    func testAddToolInputExamplesAppendsToDescriptions() async throws {
        let weather = Tool(
            name: "weather",
            description: "Get the weather.",
            parameters: ["type": "object"],
            inputExamples: [["location": "San Francisco"], ["location": "Tokyo"]]
        ) { _ in .string("sunny") }

        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        let wrapped = wrapLanguageModel(
            model: model, middleware: [.addToolInputExamples(prefix: "Examples:")]
        )
        _ = try await generateText(model: wrapped, prompt: "hi", tools: [weather])

        let sent = try XCTUnwrap(model.requests.first)
        let description = try XCTUnwrap(sent.tools.first?.description)
        XCTAssertTrue(description.hasPrefix("Get the weather."), description)
        XCTAssertTrue(description.contains("Examples:"), description)
        XCTAssertTrue(description.contains("{\"location\":\"San Francisco\"}"), description)
        XCTAssertTrue(description.contains("{\"location\":\"Tokyo\"}"), description)
    }

    func testToolsWithoutExamplesAreUntouched() async throws {
        let plain = Tool(
            name: "plain", description: "No examples.", parameters: ["type": "object"]
        ) { _ in .string("ok") }
        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        let wrapped = wrapLanguageModel(model: model, middleware: [.addToolInputExamples()])
        _ = try await generateText(model: wrapped, prompt: "hi", tools: [plain])
        XCTAssertEqual(model.requests.first?.tools.first?.description, "No examples.")
    }

    func testWrapEmbeddingModelTransformsAndWraps() async throws {
        let base = MockEmbeddingModel(vectors: [[1, 2]])
        let wrapped = wrapEmbeddingModel(model: base, middleware: [
            EmbeddingModelMiddleware(transformInput: { $0.map { $0.uppercased() } }),
            EmbeddingModelMiddleware(wrapEmbed: { texts, next in
                var response = try await next(texts)
                response.embeddings = response.embeddings.map { $0.map { $0 * 2 } }
                return response
            })
        ])

        let response = try await wrapped.embed(["ab"])
        XCTAssertEqual(response.embeddings, [[2, 4]])
        XCTAssertEqual(base.batches, [["AB"]])
        XCTAssertEqual(wrapped.provider, base.provider)
    }

    func testEmbeddingDefaultSettingsCapsBatchSize() async throws {
        let base = MockEmbeddingModel(vectors: [[1]])
        let wrapped = wrapEmbeddingModel(
            model: base, middleware: [.defaultSettings(maxBatchSize: 2)]
        )
        let response = try await wrapped.embed(["a", "b", "c", "d"])
        XCTAssertEqual(response.embeddings.count, 2)
        XCTAssertEqual(base.batches, [["a", "b"]])
    }

    func testWrapImageModelWrapsGeneration() async throws {
        let wrapped = wrapImageModel(model: StubImageModel(), middleware: [
            ImageModelMiddleware(transformRequest: { request in
                var request = request
                request.prompt = "\(request.prompt) (enhanced)"
                return request
            })
        ])
        let response = try await wrapped.generateImages(
            ImageModelRequest(prompt: "a cat")
        )
        XCTAssertEqual(response.images.count, 1)
        XCTAssertEqual(StubImageModel.lastPrompt.value, "a cat (enhanced)")
    }

    func testWrapProviderAppliesMiddlewareToEveryModelKind() throws {
        let provider = ProviderRegistry.Provider(
            languageModel: { _ in
                MockLanguageModel(parts: [.finish(reason: .stop, usage: Usage())])
            },
            embeddingModel: { _ in MockEmbeddingModel(vectors: [[1]]) }
        )
        let wrapped = wrapProvider(
            provider: provider,
            languageModelMiddleware: [.defaultSettings(temperature: 0.1)]
        )
        let registry = ProviderRegistry(providers: ["p": wrapped])
        let model = try registry.languageModel("p:any")
        XCTAssertTrue(model is WrappedLanguageModel)
        let embedding = try registry.embeddingModel("p:any")
        XCTAssertTrue(embedding is WrappedEmbeddingModel)
    }
}

private struct StubImageModel: ImageModel {
    static let lastPrompt = PromptBox()

    let provider = "stub"
    let modelID = "stub-image"

    func generateImages(_ request: ImageModelRequest) async throws -> ImageModelResponse {
        Self.lastPrompt.value = request.prompt
        return ImageModelResponse(images: [Data([0x89, 0x50])])
    }
}

private final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

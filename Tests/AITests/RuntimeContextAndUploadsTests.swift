import XCTest
@testable import AI
import AITesting

final class RuntimeContextTests: XCTestCase {

    func testRuntimeContextReachesPrepareStepAndStepResults() async throws {
        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        let seen = ContextBox()

        let result = try await generateText(
            model: model,
            prompt: "hi",
            prepareStep: { context in
                await seen.record(context.runtimeContext)
                return nil
            },
            runtimeContext: ["tenant": "acme", "requestID": "r-1"]
        )

        let observed = await seen.value
        XCTAssertEqual(observed?["tenant"], "acme")
        XCTAssertEqual(result.steps.first?.runtimeContext?["requestID"], "r-1")
    }

    func testPrepareStepCanUpdateRuntimeContextForLaterSteps() async throws {
        let tool = Tool(
            name: "ping", description: "Ping.", parameters: ["type": "object"]
        ) { _ in .string("pong") }

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "ping", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("done"), .finish(reason: .stop, usage: Usage())]
        ])

        let result = try await generateText(
            model: model,
            prompt: "go",
            tools: [tool],
            prepareStep: { context in
                let count = context.runtimeContext?["steps"]?.intValue ?? 0
                return PrepareStepResult(runtimeContext: ["steps": .number(Double(count + 1))])
            },
            runtimeContext: ["steps": .number(0)]
        )

        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.steps[0].runtimeContext?["steps"]?.intValue, 1)
        XCTAssertEqual(result.steps[1].runtimeContext?["steps"]?.intValue, 2)
    }

    func testPrepareStepSeesToolsContext() async throws {
        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        let seen = ToolsContextBox()
        _ = try await generateText(
            model: model,
            prompt: "hi",
            toolsContext: ["weather": ["unit": "celsius"]],
            prepareStep: { context in
                await seen.record(context.toolsContext)
                return nil
            }
        )
        let observed = await seen.value
        XCTAssertEqual(observed["weather"]?["unit"], "celsius")
    }

    func testTelemetrySettingsFilterContextIntoAttributes() {
        let settings = TelemetrySettings(
            functionID: "summarize",
            metadata: ["team": "ios"],
            includeRuntimeContext: ["tenant"],
            includeToolsContext: ["weather"]
        )
        let attributes = settings.attributes(
            runtimeContext: ["tenant": "acme", "secret": "do-not-log"],
            toolsContext: ["weather": ["unit": "celsius"], "other": .string("skip")]
        )

        XCTAssertEqual(attributes["ai.telemetry.functionId"], "summarize")
        XCTAssertEqual(attributes["ai.telemetry.metadata.team"], "ios")
        XCTAssertEqual(attributes["ai.runtimeContext.tenant"], "acme")
        XCTAssertNil(attributes["ai.runtimeContext.secret"])
        XCTAssertEqual(attributes["ai.toolsContext.weather"]?["unit"], "celsius")
        XCTAssertNil(attributes["ai.toolsContext.other"])
        XCTAssertTrue(TelemetrySettings.disabled.attributes(
            runtimeContext: ["tenant": "acme"], toolsContext: [:]
        ).isEmpty)
    }

    func testDisabledTelemetrySkipsSpans() async throws {
        let collector = TelemetryEventBox()
        AITelemetry.collector = collector
        defer { AITelemetry.collector = nil }

        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        _ = try await generateText(
            model: model, prompt: "hi", telemetry: .disabled
        )
        XCTAssertTrue(collector.names.isEmpty, "\(collector.names)")

        _ = try await generateText(model: model, prompt: "hi")
        XCTAssertFalse(collector.names.isEmpty)
    }
}

private final class TelemetryEventBox: AITelemetryCollector, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: AITelemetryEvent) {
        lock.lock()
        storage.append("\(event.name).\(event.phase.rawValue)")
        lock.unlock()
    }
}

private actor ContextBox {
    private(set) var value: JSONValue?
    func record(_ context: JSONValue?) { value = context }
}

private actor ToolsContextBox {
    private(set) var value: [String: JSONValue] = [:]
    func record(_ context: [String: JSONValue]) { value = context }
}

final class ToolContextAndDynamicToolTests: XCTestCase {

    func testContextSchemaRejectsBadContext() async throws {
        let tool = Tool(
            name: "weather", description: "Weather.", parameters: ["type": "object"]
        ) { _ in .string("sunny") }
            .withContextSchema(Schema.object(["apiKey": .string()]))

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "weather", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("recovered"), .finish(reason: .stop, usage: Usage())]
        ])

        let result = try await generateText(
            model: model, prompt: "weather?", tools: [tool],
            toolsContext: ["weather": ["wrong": "shape"]]
        )
        XCTAssertTrue(result.toolResults[0].isError)
        XCTAssertTrue(
            result.toolResults[0].output.stringValue?.contains("context") == true,
            "\(result.toolResults[0].output)"
        )
    }

    func testValidContextPassesThroughToExecution() async throws {
        let tool = Tool(
            name: "weather", description: "Weather.", parameters: ["type": "object"]
        ) { _, options in
            .string(options.context?["apiKey"]?.stringValue ?? "missing")
        }
            .withContextSchema(Schema.object(["apiKey": .string()]))

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "weather", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("ok"), .finish(reason: .stop, usage: Usage())]
        ])
        let result = try await generateText(
            model: model, prompt: "weather?", tools: [tool],
            toolsContext: ["weather": ["apiKey": "k-123"]]
        )
        XCTAssertEqual(result.toolResults[0].output.stringValue, "k-123")
    }

    func testDescriptionCanBeComputedFromContext() async throws {
        let tool = Tool(
            name: "weather", description: "Weather.", parameters: ["type": "object"]
        ) { _ in .string("sunny") }
            .describing { context in
                "Weather in \(context?["unit"]?.stringValue ?? "kelvin")"
            }

        let model = MockLanguageModel(parts: [
            .textDelta("ok"), .finish(reason: .stop, usage: Usage())
        ])
        _ = try await generateText(
            model: model, prompt: "hi", tools: [tool],
            toolsContext: ["weather": ["unit": "celsius"]]
        )
        XCTAssertEqual(model.requests.first?.tools.first?.description, "Weather in celsius")
    }

    func testDynamicToolsAreFlaggedThroughTheWire() async throws {
        let tool = Tool.dynamic(
            name: "runtimeThing", description: "Runtime defined."
        ) { _, _ in .string("done") }
        XCTAssertTrue(tool.isDynamic)

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "runtimeThing", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("ok"), .finish(reason: .stop, usage: Usage())]
        ])

        let stream = streamText(model: model, prompt: "go", tools: [tool])
        let chunks = UIMessageStream.chunks(from: stream.fullStream)
        var sawDynamicInput = false
        var sawDynamicOutput = false
        for try await chunk in chunks {
            if case .toolInputAvailable(_, _, _, _, let dynamic) = chunk, dynamic == true {
                sawDynamicInput = true
            }
            if case .toolOutputAvailable(_, _, _, _, let dynamic) = chunk, dynamic == true {
                sawDynamicOutput = true
            }
        }
        XCTAssertTrue(sawDynamicInput, "tool-input-available must be marked dynamic")
        XCTAssertTrue(sawDynamicOutput, "tool-output-available must be marked dynamic")
    }

    func testStaticToolsAreNotFlaggedDynamic() async throws {
        let tool = Tool(
            name: "plain", description: "Static.", parameters: ["type": "object"]
        ) { _ in .string("done") }

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "plain", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("ok"), .finish(reason: .stop, usage: Usage())]
        ])
        let stream = streamText(model: model, prompt: "go", tools: [tool])
        for try await chunk in UIMessageStream.chunks(from: stream.fullStream) {
            if case .toolInputAvailable(_, _, _, _, let dynamic) = chunk {
                XCTAssertNil(dynamic)
            }
        }
    }
}

final class ProviderReferenceTests: XCTestCase {

    func testUploadedFileBuildsContentParts() {
        let uploaded = UploadedFile(
            id: "file_123", filename: "report.pdf", sizeBytes: 10, provider: "openai"
        )
        XCTAssertEqual(uploaded.providerReference, ["openai": "file_123"])

        let file = uploaded.file(mediaType: "application/pdf")
        XCTAssertEqual(file.fileID(for: "openai"), "file_123")
        XCTAssertNil(file.fileID(for: "anthropic"))
        XCTAssertNil(file.data)
        XCTAssertNil(file.url)
    }

    func testOpenAIMapsProviderReferencesToFileIDs() {
        let message = Message(role: .user, content: [
            .text("summarize"),
            .file(FileContent(
                providerReference: ["openai": "file_123"], mediaType: "application/pdf"
            )),
            .image(ImageContent(providerReference: ["openai": "file_456"]))
        ])
        let body = OpenAIModel.responsesBody(
            for: LanguageModelRequest(messages: [message]), modelID: "gpt-5"
        )
        let content = body["input"]?.arrayValue?.first?["content"]?.arrayValue ?? []

        XCTAssertEqual(content[1]["type"], "input_file")
        XCTAssertEqual(content[1]["file_id"], "file_123")
        XCTAssertEqual(content[2]["type"], "input_image")
        XCTAssertEqual(content[2]["file_id"], "file_456")
    }

    func testAnthropicMapsProviderReferencesToFileSources() {
        let message = Message(role: .user, content: [
            .file(FileContent(
                providerReference: ["anthropic": "file_abc"], mediaType: "application/pdf"
            )),
            .image(ImageContent(providerReference: ["anthropic": "file_img"]))
        ])
        let body = AnthropicModel.requestBody(
            for: LanguageModelRequest(messages: [message]), modelID: "claude-sonnet-5"
        )
        let content = body["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []

        XCTAssertEqual(content[0]["type"], "document")
        XCTAssertEqual(content[0]["source"]?["type"], "file")
        XCTAssertEqual(content[0]["source"]?["file_id"], "file_abc")
        XCTAssertEqual(content[1]["type"], "image")
        XCTAssertEqual(content[1]["source"]?["file_id"], "file_img")
    }

    func testProviderReferencesAreIgnoredByOtherProviders() {
        let message = Message(role: .user, content: [
            .file(FileContent(
                providerReference: ["openai": "file_123"], mediaType: "application/pdf"
            ))
        ])
        let body = AnthropicModel.requestBody(
            for: LanguageModelRequest(messages: [message]), modelID: "claude-sonnet-5"
        )
        let content = body["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        XCTAssertTrue(
            content.isEmpty || content[0]["source"]?["file_id"] == nil,
            "an openai reference must not be sent to anthropic as a file id"
        )
    }
}

final class RemoteContentInliningTests: XCTestCase {

    func testModelsThatSupportURLsKeepThem() async throws {
        let messages = [
            Message(role: .user, content: [
                .image(ImageContent(url: URL(string: "https://example.com/cat.png")!))
            ])
        ]
        let unchanged = try await RemoteContent.inlineUnsupportedURLs(
            in: messages, model: MockLanguageModel(parts: [])
        )
        guard case .image(let image)? = unchanged.first?.content.first else {
            return XCTFail("expected an image part")
        }
        XCTAssertEqual(image.url?.absoluteString, "https://example.com/cat.png")
        XCTAssertNil(image.data)
    }

    func testBedrockDeclaresNoRemoteURLSupport() {
        let bedrock = BedrockModel("anthropic.claude-sonnet-4-5-20250929-v1:0", apiKey: "k")
        XCTAssertFalse(bedrock.supportsRemoteURL(
            URL(string: "https://example.com/cat.png")!, mediaType: "image/png"
        ))
        XCTAssertTrue(MockLanguageModel(parts: []).supportsRemoteURL(
            URL(string: "https://example.com/cat.png")!, mediaType: "image/png"
        ))
    }

    func testDataURLsAndUploadedReferencesAreLeftAlone() async throws {
        let messages = [
            Message(role: .user, content: [
                .image(ImageContent(url: URL(string: "data:image/png;base64,AAAA")!)),
                .file(FileContent(
                    providerReference: ["openai": "file_1"], mediaType: "application/pdf"
                ))
            ])
        ]
        let result = try await RemoteContent.inlineUnsupportedURLs(
            in: messages, model: NoURLModel()
        )
        guard case .image(let image)? = result.first?.content.first else {
            return XCTFail("expected an image part")
        }
        XCTAssertNotNil(image.url, "data: URLs are already inline")
    }

    func testNonHTTPURLsAreRejectedRatherThanFetched() async {
        let messages = [
            Message(role: .user, content: [
                .file(FileContent(url: URL(fileURLWithPath: "/etc/passwd"), mediaType: "text/plain"))
            ])
        ]
        do {
            _ = try await RemoteContent.inlineUnsupportedURLs(
                in: messages, model: NoURLModel()
            )
            XCTFail("expected a rejection for a file:// URL")
        } catch let error as AIError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("http"), message)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }
}

private struct NoURLModel: LanguageModel {
    let provider = "nourl"
    let modelID = "nourl"

    func supportsRemoteURL(_ url: URL, mediaType: String?) -> Bool { false }

    func stream(
        _ request: LanguageModelRequest
    ) async throws -> AsyncThrowingStream<StreamPart, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class SmallHelperTests: XCTestCase {

    func testFilterActiveTools() {
        let tools: [any AIToolProtocol] = [
            Tool(name: "a", description: "", parameters: ["type": "object"]),
            Tool(name: "b", description: "", parameters: ["type": "object"])
        ]
        XCTAssertEqual(filterActiveTools(tools, activeTools: ["b"]).map(\.name), ["b"])
        XCTAssertEqual(filterActiveTools(tools, activeTools: nil).map(\.name), ["a", "b"])
        XCTAssertTrue(filterActiveTools(tools, activeTools: []).isEmpty)
    }

    func testIdGenerators() {
        let plain = generateId()
        XCTAssertEqual(plain.count, 16)
        XCTAssertNotEqual(plain, generateId())

        let prefixed = createIdGenerator(prefix: "msg", separator: "_", size: 8)()
        XCTAssertTrue(prefixed.hasPrefix("msg_"), prefixed)
        XCTAssertEqual(prefixed.count, 4 + 8)

        let limited = createIdGenerator(alphabet: "ab", size: 32)()
        XCTAssertTrue(limited.allSatisfy { $0 == "a" || $0 == "b" }, limited)
    }

    func testGeneratedFileAccessors() {
        let file = GeneratedFile(data: Data([0x1, 0x2]), mediaType: "image/png")
        XCTAssertEqual(file.bytes, [0x1, 0x2])
        XCTAssertEqual(file.base64, Data([0x1, 0x2]).base64EncodedString())

        let result = GenerateImageResult(
            image: Data([0x1]), images: [Data([0x1]), Data([0x2])], revisedPrompts: []
        )
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.file.mediaType, "image/png")
    }

    func testNewErrorDescriptions() {
        XCTAssertTrue(
            AIError.invalidToolInput(tool: "t", reason: "bad").description.contains("t")
        )
        XCTAssertTrue(
            AIError.missingToolResults(["c1", "c2"]).description.contains("c1, c2")
        )
        XCTAssertTrue(
            AIError.unsupportedFunctionality("x").description.contains("Unsupported")
        )
    }
}

final class TransportHookTests: XCTestCase {

    func testPrepareSendMessagesRequestOverridesHeadersAndBody() async {
        let transport = HTTPChatTransport(
            api: URL(string: "https://example.com/api/chat")!,
            headers: ["x-static": "1"],
            prepareSendMessagesRequest: { request in
                PreparedChatRequest(
                    headers: ["authorization": "Bearer fresh"],
                    body: ["messages": .array(request.messages.suffix(1).map(\.wire))]
                )
            }
        )
        XCTAssertNotNil(transport.prepareSendMessagesRequest)
        XCTAssertEqual(transport.headers["x-static"], "1")

        let hook = try? XCTUnwrap(transport.prepareSendMessagesRequest)
        let prepared = try? await hook?(
            ChatRequest(chatID: "c", messages: [.user("one"), .user("two")])
        )
        XCTAssertEqual(prepared?.headers["authorization"], "Bearer fresh")
        XCTAssertEqual(prepared?.body?["messages"]?.arrayValue?.count, 1)
    }

    func testPrepareReconnectRequestCanRewriteTheURL() async {
        let transport = HTTPChatTransport(
            api: URL(string: "https://example.com/api/chat")!,
            prepareReconnectToStreamRequest: { chatID in
                PreparedChatRequest(
                    api: URL(string: "https://example.com/resume/\(chatID)")!
                )
            }
        )
        let hook = try? XCTUnwrap(transport.prepareReconnectToStreamRequest)
        let prepared = try? await hook?("abc")
        XCTAssertEqual(prepared?.api?.absoluteString, "https://example.com/resume/abc")
    }
}

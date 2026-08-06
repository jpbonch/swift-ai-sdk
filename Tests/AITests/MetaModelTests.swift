import XCTest
@testable import AI

final class MetaModelTests: XCTestCase {

    private func body(
        _ request: LanguageModelRequest, modelID: String = "muse-spark-1.2"
    ) -> [String: JSONValue] {
        OpenAIModel.responsesBody(
            for: request, modelID: modelID, dialect: MetaModel.dialect
        ).objectValue ?? [:]
    }

    private func fnTool(_ name: String = "weather") -> Tool {
        Tool(name: name, description: "w", parameters: ["type": "object"]) { _ in "x" }
    }

    func testIdentityAndDefaultBaseURL() {
        let model = MetaModel("muse-spark-1.2", apiKey: "k")
        XCTAssertEqual(model.provider, "meta")
        XCTAssertEqual(model.modelID, "muse-spark-1.2")
        XCTAssertEqual(MetaModel.defaultBaseURL.absoluteString, "https://api.meta.ai/v1")
        XCTAssertEqual(MetaModel.chat("muse-spark-1.2", apiKey: "k").provider, "meta")
    }

    func testResponsesRequestTargetsResponsesPath() throws {
        let config = OpenAIModel.ResponsesConfig(
            apiKey: "k",
            baseURL: MetaModel.defaultBaseURL,
            headers: ["x-team": "ios"],
            urlSession: .shared,
            dialect: MetaModel.dialect
        )
        let urlRequest = try OpenAIModel.buildResponsesRequest(
            config, modelID: "muse-spark-1.2",
            request: LanguageModelRequest(messages: [.user("hi")])
        )
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.meta.ai/v1/responses")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-team"), "ios")
    }

    func testSystemPromptsRideTheDeveloperRole() {
        let items = body(LanguageModelRequest(
            messages: [.system("be terse"), .user("hi")]
        ))["input"]?.arrayValue
        XCTAssertEqual(items?.first?["role"], "developer")
    }

    func testReasoningEffortIsNestedAndNoneFallsBackToDefault() {
        let high = body(LanguageModelRequest(messages: [.user("hi")], reasoning: .high))
        XCTAssertEqual(high["reasoning"]?["effort"], "high")
        XCTAssertEqual(high["reasoning"]?["summary"], "detailed")

        let xhigh = body(LanguageModelRequest(messages: [.user("hi")], reasoning: .xhigh))
        XCTAssertEqual(xhigh["reasoning"]?["effort"], "xhigh")

        let none = body(LanguageModelRequest(messages: [.user("hi")], reasoning: .none))
        XCTAssertNil(none["reasoning"])
    }

    func testSamplingParametersSurviveOnAReasoningModel() {
        let sent = body(LanguageModelRequest(
            messages: [.user("hi")], temperature: 0.4, topP: 0.9
        ))
        XCTAssertEqual(sent["temperature"], 0.4)
        XCTAssertEqual(sent["top_p"], 0.9)
    }

    func testProviderToolsUseTheMetaNamespace() {
        let webSearch = MetaModel.Tools.webSearch()
        XCTAssertEqual(webSearch.provider, "meta")
        XCTAssertEqual(webSearch.id, "meta.web_search")
        XCTAssertFalse(webSearch.hasExecutor)

        let request = LanguageModelRequest(
            messages: [.user("hi")],
            tools: [
                fnTool(),
                MetaModel.Tools.webSearch(
                    searchContextSize: "high",
                    userLocation: .init(country: "GB", city: "London")
                ),
                MetaModel.Tools.toolSearch(),
                OpenAIModel.Tools.webSearch()
            ]
        )
        let tools = body(request)["tools"]?.arrayValue
        XCTAssertEqual(tools?.count, 3)

        let web = tools?.first { $0["type"] == "web_search" }
        XCTAssertEqual(web?["search_context_size"], "high")
        XCTAssertEqual(web?["user_location"]?["type"], "approximate")
        XCTAssertEqual(web?["user_location"]?["country"], "GB")
        XCTAssertEqual(web?["user_location"]?["city"], "London")
        XCTAssertNil(web?["user_location"]?["region"])

        XCTAssertNotNil(tools?.first { $0["type"] == "tool_search" })
    }

    func testStructuredOutputUsesTextFormat() {
        let sent = body(LanguageModelRequest(
            messages: [.user("hi")],
            responseFormat: .json(schema: ["type": "object"], name: "answer")
        ))
        XCTAssertEqual(sent["text"]?["format"]?["type"], "json_schema")
        XCTAssertEqual(sent["text"]?["format"]?["name"], "answer")
        XCTAssertNil(sent["response_format"])
    }

    func testProviderOptionsMergeOntoTheBody() {
        let sent = body(LanguageModelRequest(
            messages: [.user("hi")],
            providerOptions: .object([
                "store": .bool(false),
                "include": .array([.string("reasoning.encrypted_content")]),
                "prompt_cache_retention": .string("24h")
            ])
        ))
        XCTAssertEqual(sent["store"], .bool(false))
        XCTAssertEqual(sent["include"]?.arrayValue?.first, "reasoning.encrypted_content")
        XCTAssertEqual(sent["prompt_cache_retention"], "24h")
    }

    func testChatWireSendsEffortAndDropsNone() {
        let style = OpenAIChatModel.ReasoningWireStyle.forProvider("meta")
        let xhigh = OpenAIChatModel.reasoningFields(
            .xhigh, style: style, modelID: "muse-spark-1.2"
        )
        XCTAssertEqual(xhigh["reasoning_effort"], "xhigh")
        XCTAssertTrue(
            OpenAIChatModel.reasoningFields(.none, style: style, modelID: "muse-spark-1.2").isEmpty
        )
    }

    func testContextWindowIsRegisteredForMuseSpark() {
        XCTAssertEqual(
            ModelContextWindows.resolve(provider: "meta", modelID: "muse-spark-1.2"),
            1_048_576
        )
    }

    func testOpenAIDialectIsUnchanged() {
        let sent = OpenAIModel.responsesBody(
            for: LanguageModelRequest(
                messages: [.system("be terse"), .user("hi")], temperature: 0.4
            ),
            modelID: "gpt-5.6-luna"
        ).objectValue ?? [:]
        XCTAssertEqual(sent["input"]?.arrayValue?.first?["role"], "developer")
        XCTAssertNil(sent["temperature"])
    }

    func testChatRejectsResponsesOnlyTools() async {
        let model = MetaModel.chat("muse-spark-1.2", apiKey: "k")
        let request = LanguageModelRequest(
            messages: [.user("hi")],
            tools: [MetaModel.Tools.webSearch()]
        )
        do {
            _ = try await model.stream(request)
            XCTFail("expected the chat wire to reject a Responses-only tool")
        } catch let error as AIError {
            guard case .unsupportedFunctionality(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Responses API"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

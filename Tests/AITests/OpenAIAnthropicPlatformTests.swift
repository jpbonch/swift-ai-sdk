import XCTest
@testable import AI

final class AnthropicToolPropertyTests: XCTestCase {

    private func toolWire(_ tool: any AIToolProtocol) -> JSONValue? {
        AnthropicModel.requestBody(
            for: LanguageModelRequest(messages: [.user("hi")], tools: [tool]),
            modelID: "claude-sonnet-5"
        )["tools"]?[0]
    }

    func testStrictDeferLoadingAndAllowedCallers() {
        let tool = Tool(
            name: "deleteFile", description: "Delete.", parameters: ["type": "object"]
        ) { _ in .null }
            .loading(ToolLoading(
                strict: true,
                deferLoading: true,
                allowedCallers: ["direct", "code_execution_20260120"],
                eagerInputStreaming: true
            ))

        let wire = toolWire(tool)
        XCTAssertEqual(wire?["strict"], .bool(true))
        XCTAssertEqual(wire?["defer_loading"], .bool(true))
        XCTAssertEqual(
            wire?["allowed_callers"], .array(["direct", "code_execution_20260120"])
        )
        XCTAssertEqual(wire?["eager_input_streaming"], .bool(true))
    }

    func testCacheControlBreakpointAndCodeExecutionOnlyHelpers() {
        let cached = Tool(
            name: "search", description: "Search.", parameters: ["type": "object"]
        ) { _ in .null }.loading(.ephemeralCache())
        XCTAssertEqual(toolWire(cached)?["cache_control"]?["type"], "ephemeral")

        let sandboxed = Tool(
            name: "query", description: "Query.", parameters: ["type": "object"]
        ) { _ in .null }.loading(.codeExecutionOnly())
        XCTAssertEqual(
            toolWire(sandboxed)?["allowed_callers"], .array(["code_execution_20260120"])
        )
        XCTAssertNil(toolWire(sandboxed)?["strict"])
    }

    func testInputExamplesGoNativeOnAnthropic() {
        let tool = Tool(
            name: "weather",
            description: "Weather.",
            parameters: ["type": "object"],
            inputExamples: [["city": "SF"], ["city": "Tokyo"]]
        ) { _ in .null }

        let wire = toolWire(tool)
        XCTAssertEqual(wire?["input_examples"]?.arrayValue?.count, 2)
        XCTAssertEqual(wire?["input_examples"]?[0]?["city"], "SF")
        XCTAssertEqual(
            wire?["description"], "Weather.",
            "Anthropic takes input_examples natively, so the description stays clean"
        )
    }

    func testPlainToolsCarryNoExtraProperties() {
        let tool = Tool(
            name: "plain", description: "Plain.", parameters: ["type": "object"]
        ) { _ in .null }
        let wire = toolWire(tool)
        XCTAssertNil(wire?["strict"])
        XCTAssertNil(wire?["defer_loading"])
        XCTAssertNil(wire?["allowed_callers"])
        XCTAssertNil(wire?["cache_control"])
        XCTAssertNil(wire?["input_examples"])
    }

    func testMCPToolsetAndItsBetaHeader() {
        let toolset = AnthropicModel.Tools.mcpToolset(
            serverURL: "https://mcp.example.com",
            serverName: "docs",
            authorizationToken: "tok",
            allowedTools: ["search"],
            deferLoading: true
        )
        XCTAssertEqual(toolset.id, "anthropic.mcp_toolset")
        XCTAssertEqual(toolset.args["type"], "mcp_toolset")
        XCTAssertEqual(toolset.args["mcp_server_name"], "docs")

        // The server belongs in a top-level `mcp_servers` array, so the request
        // body is what has to be checked, not just the tool entry.
        let request = LanguageModelRequest(messages: [.user("hi")], tools: [toolset])
        let body = AnthropicModel.requestBody(for: request, modelID: "claude-opus-5")

        let servers = body["mcp_servers"]?.arrayValue
        XCTAssertEqual(servers?.count, 1)
        XCTAssertEqual(servers?.first?["type"], "url")
        XCTAssertEqual(servers?.first?["url"], "https://mcp.example.com")
        XCTAssertEqual(servers?.first?["name"], "docs")
        XCTAssertEqual(servers?.first?["authorization_token"], "tok")

        let wire = body["tools"]?.arrayValue?.first { $0["type"] == "mcp_toolset" }
        XCTAssertEqual(wire?["mcp_server_name"], "docs")
        XCTAssertEqual(wire?["default_config"]?["defer_loading"], .bool(true))
        XCTAssertEqual(wire?["default_config"]?["enabled"], .bool(false))
        XCTAssertEqual(wire?["configs"]?["search"]?["enabled"], .bool(true))
        XCTAssertNil(wire?["mcp_server"], "the server must not stay inline on the tool")
        XCTAssertNil(wire?["__mcp_server"], "the private carrier key must be stripped")
        XCTAssertNil(wire?["authorization_token"])
        XCTAssertNil(wire?["allowed_tools"])

        let betas = AnthropicModel.betaFlags(for: request)
        XCTAssertTrue(betas.contains("mcp-client-2025-11-20"), "\(betas)")
    }

    func testNewestToolVersionsCarryBetaHeaders() {
        let request = LanguageModelRequest(messages: [.user("hi")], tools: [
            AnthropicModel.Tools.webSearch(version: "web_search_20260318"),
            AnthropicModel.Tools.webFetch(version: "web_fetch_20260309"),
            AnthropicModel.Tools.codeExecution(version: "code_execution_20260521")
        ])
        let betas = AnthropicModel.betaFlags(for: request)
        XCTAssertTrue(betas.contains("code-execution-web-tools-2026-02-09"), "\(betas)")
    }
}

final class AnthropicPlatformClientTests: XCTestCase {

    func testBatchLifecycle() async throws {
        StubTransport.reset(response: .object(["id": "msgbatch_1"]))
        let batches = AnthropicBatchClient(apiKey: "k", urlSession: StubTransport.session())

        let id = try await batches.create([
            .init(customID: "r1", model: "claude-sonnet-5", messages: [.user("One")]),
            .init(customID: "r2", model: "claude-sonnet-5", messages: [.user("Two")])
        ])
        XCTAssertEqual(id, "msgbatch_1")

        _ = try await batches.get(id)
        _ = try await batches.cancel(id)
        _ = try await batches.delete(id)

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].path, "/v1/messages/batches")
        XCTAssertEqual(recorded[0].host, "api.anthropic.com")
        let requests = recorded[0].body?["requests"]?.arrayValue
        XCTAssertEqual(requests?.count, 2)
        XCTAssertEqual(requests?[0]["custom_id"], "r1")
        XCTAssertEqual(requests?[0]["params"]?["model"], "claude-sonnet-5")
        XCTAssertNil(
            requests?[0]["params"]?["stream"],
            "batch params must not ask for streaming"
        )

        XCTAssertEqual(recorded[1].path, "/v1/messages/batches/msgbatch_1")
        XCTAssertEqual(recorded[2].path, "/v1/messages/batches/msgbatch_1/cancel")
        XCTAssertEqual(recorded[3].method, "DELETE")
    }

    func testBatchAuthHeaders() async throws {
        StubTransport.reset(response: .object(["id": "b"]))
        let batches = AnthropicBatchClient(apiKey: "secret", urlSession: StubTransport.session())
        _ = try await batches.list(limit: 5)

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertNil(request.authorization, "Anthropic authenticates with x-api-key")
        XCTAssertEqual(request.queryValue("limit"), "5")
    }

    func testModelsClient() async throws {
        StubTransport.reset(response: .object(["data": .array([])]))
        let models = AnthropicModelsClient(apiKey: "k", urlSession: StubTransport.session())
        _ = try await models.list(limit: 20)
        _ = try await models.get("claude-sonnet-5")

        XCTAssertEqual(StubTransport.requests.map(\.path), ["/v1/models", "/v1/models/claude-sonnet-5"])
    }

    func testCountTokens() async throws {
        StubTransport.reset(response: .object(["input_tokens": .number(2095)]))
        let model = AnthropicModel(
            "claude-sonnet-5", apiKey: "k", urlSession: StubTransport.session()
        )
        let tokens = try await model.countTokens([.user("Hello there")])
        XCTAssertEqual(tokens, 2095)

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1/messages/count_tokens")
        XCTAssertNil(request.body?["max_tokens"], "count_tokens takes no max_tokens")
        XCTAssertNil(request.body?["stream"])
    }
}

final class OpenAIPlatformClientTests: XCTestCase {

    func testConversationsLifecycle() async throws {
        StubTransport.reset(response: .object(["id": "conv_1", "deleted": .bool(true)]))
        let conversations = OpenAIConversationsClient(
            apiKey: "k", urlSession: StubTransport.session()
        )

        let id = try await conversations.createFromMessages([
            .system("Be brief."), .user("Hello"), .assistant("Hi")
        ])
        XCTAssertEqual(id, "conv_1")

        _ = try await conversations.items(id, limit: 10, order: "asc")
        _ = try await conversations.addItems(id, items: [
            .object(["role": "user", "content": "More"])
        ])
        _ = try await conversations.update(id, metadata: ["topic": "greeting"])
        _ = try await conversations.delete(id)

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].path, "/v1/conversations")
        XCTAssertEqual(recorded[0].authorization, "Bearer k")
        XCTAssertEqual(recorded[0].body?["items"]?.arrayValue?.count, 3)
        XCTAssertEqual(recorded[0].body?["items"]?[0]?["role"], "system")

        XCTAssertEqual(recorded[1].path, "/v1/conversations/conv_1/items")
        XCTAssertEqual(recorded[1].queryValue("order"), "asc")
        XCTAssertEqual(recorded[2].method, "POST")
        XCTAssertEqual(recorded[3].body?["metadata"]?["topic"], "greeting")
        XCTAssertEqual(recorded[4].method, "DELETE")
    }

    func testVectorStoreCreateAndSearch() async throws {
        StubTransport.reset(response: .object(["id": "vs_1"]))
        let stores = OpenAIVectorStoresClient(apiKey: "k", urlSession: StubTransport.session())

        let id = try await stores.create(
            name: "docs", fileIDs: ["file_1"], expiresAfterDays: 7
        )
        _ = try await stores.search(id, query: "refunds", maxResults: 5, rewriteQuery: true)
        _ = try await stores.addFile(id, fileID: "file_2", attributes: ["team": "support"])
        _ = try await stores.removeFile(id, fileID: "file_2")

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].path, "/v1/vector_stores")
        XCTAssertEqual(recorded[0].body?["file_ids"], .array(["file_1"]))
        XCTAssertEqual(recorded[0].body?["expires_after"]?["days"], .number(7))

        XCTAssertEqual(recorded[1].path, "/v1/vector_stores/vs_1/search")
        XCTAssertEqual(recorded[1].body?["query"], "refunds")
        XCTAssertEqual(recorded[1].body?["max_num_results"], .number(5))
        XCTAssertEqual(recorded[1].body?["rewrite_query"], .bool(true))

        XCTAssertEqual(recorded[2].path, "/v1/vector_stores/vs_1/files")
        XCTAssertEqual(recorded[3].method, "DELETE")
    }

    func testBatchAndContainerClients() async throws {
        StubTransport.reset(response: .object(["id": "batch_1"]))
        let batches = OpenAIBatchClient(apiKey: "k", urlSession: StubTransport.session())
        let batchID = try await batches.create(inputFileID: "file_in")
        _ = try await batches.cancel(batchID)

        XCTAssertEqual(StubTransport.requests[0].path, "/v1/batches")
        XCTAssertEqual(StubTransport.requests[0].body?["endpoint"], "/v1/responses")
        XCTAssertEqual(StubTransport.requests[0].body?["completion_window"], "24h")
        XCTAssertEqual(StubTransport.requests[1].path, "/v1/batches/batch_1/cancel")

        StubTransport.reset(response: .object(["id": "cntr_1"]))
        let containers = OpenAIContainersClient(apiKey: "k", urlSession: StubTransport.session())
        let containerID = try await containers.create(
            name: "sandbox", fileIDs: ["file_1"], expiresAfterMinutes: 20
        )
        _ = try await containers.delete(containerID)
        XCTAssertEqual(StubTransport.requests[0].path, "/v1/containers")
        XCTAssertEqual(StubTransport.requests[0].body?["expires_after"]?["minutes"], .number(20))
        XCTAssertEqual(StubTransport.requests[1].method, "DELETE")
    }

    func testModerationsVerdict() async throws {
        StubTransport.reset(response: .object([
            "results": .array([
                .object([
                    "flagged": .bool(true),
                    "categories": .object([
                        "violence": .bool(true),
                        "hate": .bool(false),
                        "self-harm": .bool(true)
                    ])
                ])
            ])
        ]))
        let moderations = OpenAIModerationsClient(
            apiKey: "k", urlSession: StubTransport.session()
        )
        let verdict = try await moderations.moderate("something")

        XCTAssertTrue(verdict.flagged)
        XCTAssertEqual(verdict.categories, ["self-harm", "violence"])
        XCTAssertEqual(StubTransport.requests.first?.path, "/v1/moderations")
        XCTAssertEqual(StubTransport.requests.first?.body?["model"], "omni-moderation-latest")
    }

    func testSoraVideoModelPollsToCompletion() async throws {
        StubTransport.reset(response: .object(["id": "video_1", "status": "completed"]))
        let model = OpenAIVideoModel(
            "sora-2", apiKey: "k", pollInterval: .milliseconds(1),
            urlSession: StubTransport.session()
        )
        let response = try await model.generateVideos(
            VideoModelRequest(prompt: "a cat surfing", aspectRatio: "1280x720", duration: 8)
        )

        XCTAssertFalse(response.videos.isEmpty)
        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].path, "/v1/videos")
        XCTAssertEqual(recorded[0].body?["prompt"], "a cat surfing")
        XCTAssertEqual(recorded[0].body?["seconds"], "8")
        XCTAssertEqual(recorded[0].body?["size"], "1280x720")
        XCTAssertEqual(recorded[1].path, "/v1/videos/video_1")
        XCTAssertEqual(recorded.last?.path, "/v1/videos/video_1/content")
    }

    func testSoraSurfacesFailures() async {
        StubTransport.reset(response: .object(["id": "video_1", "status": "failed"]))
        let model = OpenAIVideoModel(
            apiKey: "k", pollInterval: .milliseconds(1), urlSession: StubTransport.session()
        )
        do {
            _ = try await model.generateVideos(VideoModelRequest(prompt: "x"))
            XCTFail("expected a failure")
        } catch let error as AIError {
            guard case .transport(let message) = error else {
                return XCTFail("expected transport, got \(error)")
            }
            XCTAssertTrue(message.contains("failed"), message)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }
}

final class OpenAIMultiAgentTests: XCTestCase {

    private func request(_ model: OpenAIModel) throws -> URLRequest {
        let config = OpenAIModel.ResponsesConfig(
            apiKey: "k",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            headers: [:],
            urlSession: .shared,
            multiAgent: OpenAIModel.MultiAgent(enabled: true, maxConcurrentSubagents: 3)
        )
        return try OpenAIModel.buildResponsesRequest(
            config, modelID: "gpt-5.6-sol",
            request: LanguageModelRequest(messages: [.user("Review this diff")])
        )
    }

    func testMultiAgentBodyAndBetaHeader() throws {
        let model = OpenAIModel(
            "gpt-5.6-sol", apiKey: "k",
            multiAgent: OpenAIModel.MultiAgent(maxConcurrentSubagents: 3)
        )
        let urlRequest = try request(model)

        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "OpenAI-Beta"), "responses_multi_agent=v1"
        )
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["multi_agent"]?["enabled"], .bool(true))
        XCTAssertEqual(json["multi_agent"]?["max_concurrent_subagents"], .number(3))
    }

    func testMultiAgentIsAbsentByDefault() throws {
        let config = OpenAIModel.ResponsesConfig(
            apiKey: "k",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            headers: [:],
            urlSession: .shared
        )
        let urlRequest = try OpenAIModel.buildResponsesRequest(
            config, modelID: "gpt-5.6",
            request: LanguageModelRequest(messages: [.user("hi")])
        )
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "OpenAI-Beta"))
        let json = try JSONDecoder().decode(
            JSONValue.self, from: XCTUnwrap(urlRequest.httpBody)
        )
        XCTAssertNil(json["multi_agent"])
    }

    func testMultiAgentCallItemsSurfaceAsMetadataNotToolCalls() {
        let wire = OpenAIModel.MultiAgent(enabled: true, maxConcurrentSubagents: 2).wire
        XCTAssertEqual(wire["max_concurrent_subagents"], .number(2))
        XCTAssertEqual(OpenAIModel.MultiAgent.betaHeader, "responses_multi_agent=v1")
    }
}

import XCTest
@testable import AI

final class GoogleInteractionsRequestTests: XCTestCase {

    private func body(
        _ model: GoogleInteractionsModel, _ request: LanguageModelRequest, stream: Bool = true
    ) -> JSONValue {
        model.requestBody(for: request, stream: stream)
    }

    func testModelInteractionShape() {
        let model = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k")
        let wire = body(model, LanguageModelRequest(
            messages: [.system("Be brief."), .user("Hi")],
            maxOutputTokens: 512,
            temperature: 0.3,
            reasoning: .high
        ))

        XCTAssertEqual(wire["model"], "gemini-3.6-flash")
        XCTAssertNil(wire["agent"])
        XCTAssertEqual(wire["stream"], .bool(true))
        XCTAssertEqual(wire["system_instruction"], "Be brief.")
        XCTAssertEqual(wire["input"]?.arrayValue?.count, 1)
        XCTAssertEqual(wire["input"]?[0]?["type"], "user_input")
        XCTAssertEqual(wire["input"]?[0]?["content"]?[0]?["text"], "Hi")
        XCTAssertEqual(wire["generation_config"]?["max_output_tokens"], .number(512))
        XCTAssertEqual(wire["generation_config"]?["temperature"], .number(0.3))
        XCTAssertEqual(wire["generation_config"]?["thinking_level"], "high")
    }

    func testStoreDefaultsToFalseAndIsExplicit() {
        let stateless = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k")
        XCTAssertEqual(
            body(stateless, LanguageModelRequest(messages: [.user("Hi")]))["store"], .bool(false),
            "the client must opt out of Google's default server-side storage"
        )

        var stateful = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k", store: true)
        stateful.previousInteractionID = "v1_abc"
        let wire = body(stateful, LanguageModelRequest(messages: [.user("And then?")]))
        XCTAssertEqual(wire["store"], .bool(true))
        XCTAssertEqual(wire["previous_interaction_id"], "v1_abc")
    }

    func testBackgroundAndAgentTargets() {
        let background = GoogleInteractionsModel(
            "gemini-3.6-flash", apiKey: "k", store: true, background: true
        )
        XCTAssertEqual(
            body(background, LanguageModelRequest(messages: [.user("Long task")]))["background"],
            .bool(true)
        )

        let agent = GoogleInteractionsModel.agent(
            "deep-research-preview-04-2026",
            apiKey: "k",
            agentConfig: ["type": "antigravity", "max_tokens": .number(1000)]
        )
        let wire = body(agent, LanguageModelRequest(messages: [.user("Research this")]))
        XCTAssertEqual(wire["agent"], "deep-research-preview-04-2026")
        XCTAssertNil(wire["model"])
        XCTAssertEqual(wire["agent_config"]?["type"], "antigravity")
        XCTAssertNil(
            wire["generation_config"],
            "agent_config replaces generation_config"
        )
    }

    func testToolsAndStructuredOutput() {
        let weather = Tool(
            name: "weather", description: "Get weather.",
            parameters: ["type": "object", "properties": ["city": ["type": "string"]]]
        ) { _ in .string("sunny") }

        let model = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k")
        let wire = body(model, LanguageModelRequest(
            messages: [.user("Weather?")],
            tools: [weather],
            toolChoice: .required,
            responseFormat: .json(
                schema: ["type": "object"], name: "output", description: nil
            )
        ))

        XCTAssertEqual(wire["tools"]?[0]?["type"], "function")
        XCTAssertEqual(wire["tools"]?[0]?["name"], "weather")
        XCTAssertEqual(wire["tools"]?[0]?["parameters"]?["type"], "object")
        XCTAssertEqual(wire["response_json_schema"]?["type"], "object")
        XCTAssertEqual(wire["generation_config"]?["tool_choice"], "any")
    }

    func testToolCallsAndResultsRoundTripAsSteps() {
        let model = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k")
        let wire = body(model, LanguageModelRequest(messages: [
            .user("Weather?"),
            Message(role: .assistant, content: [
                .text("Checking."),
                .toolCall(ToolCall(id: "c1", name: "weather", arguments: ["city": "SF"]))
            ]),
            Message(role: .tool, content: [
                .toolResult(ToolResult(toolCallID: "c1", name: "weather", output: ["tempF": 70]))
            ])
        ]))

        let steps = try? XCTUnwrap(wire["input"]?.arrayValue)
        XCTAssertEqual(steps?.count, 4)
        XCTAssertEqual(steps?[0]["type"], "user_input")
        XCTAssertEqual(steps?[1]["type"], "model_output")
        XCTAssertEqual(steps?[2]["type"], "function_call")
        XCTAssertEqual(steps?[2]["id"], "c1")
        XCTAssertEqual(steps?[2]["arguments"]?["city"], "SF")
        XCTAssertEqual(steps?[3]["type"], "function_result")
        XCTAssertEqual(steps?[3]["call_id"], "c1")
        XCTAssertEqual(steps?[3]["name"], "weather")
        XCTAssertTrue(
            steps?[3]["result"]?[0]?["text"]?.stringValue?.contains("70") == true,
            "\(String(describing: steps?[3]))"
        )
    }

    func testMultimodalInputParts() {
        let model = GoogleInteractionsModel("gemini-3.6-flash", apiKey: "k")
        let wire = body(model, LanguageModelRequest(messages: [
            Message(role: .user, content: [
                .text("Describe"),
                .image(ImageContent(url: URL(string: "https://files/x.png")!, mediaType: "image/png")),
                .file(FileContent(
                    url: URL(string: "https://files/a.mp3")!, mediaType: "audio/mpeg"
                ))
            ])
        ]))

        let content = wire["input"]?[0]?["content"]?.arrayValue
        XCTAssertEqual(content?[1]["type"], "image")
        XCTAssertEqual(content?[1]["uri"], "https://files/x.png")
        XCTAssertEqual(content?[2]["type"], "audio")
        XCTAssertEqual(content?[2]["mime_type"], "audio/mpeg")
    }

    func testThinkingLevelMapping() {
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.none), "minimal")
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.minimal), "minimal")
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.low), "low")
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.medium), "medium")
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.high), "high")
        XCTAssertEqual(GoogleInteractionsModel.thinkingLevel(.xhigh), "high")
        XCTAssertNil(GoogleInteractionsModel.thinkingLevel(.providerDefault))
    }
}

final class GoogleInteractionsStreamTests: XCTestCase {

    private func decode(_ events: [JSONValue]) -> [StreamPart] {
        var decoder = InteractionStreamDecoder()
        var parts: [StreamPart] = []
        for event in events { parts.append(contentsOf: decoder.consume(event)) }
        parts.append(contentsOf: decoder.finish())
        return parts
    }

    func testTextAndThoughtStepsBecomeDeltas() {
        let parts = decode([
            ["event_type": "interaction.created", "interaction": ["id": "v1_abc"]],
            ["event_type": "step.start", "index": .number(0), "step": ["type": "thought"]],
            [
                "event_type": "step.delta", "index": .number(0),
                "delta": ["type": "text", "text": "thinking"]
            ],
            ["event_type": "step.stop", "index": .number(0)],
            ["event_type": "step.start", "index": .number(1), "step": ["type": "model_output"]],
            [
                "event_type": "step.delta", "index": .number(1),
                "delta": ["type": "text", "text": "Hello "]
            ],
            [
                "event_type": "step.delta", "index": .number(1),
                "delta": ["type": "text", "text": "world"]
            ],
            ["event_type": "step.stop", "index": .number(1)],
            [
                "event_type": "interaction.completed",
                "interaction": ["id": "v1_abc", "usage": [
                    "total_input_tokens": .number(7),
                    "total_output_tokens": .number(20),
                    "total_thought_tokens": .number(22),
                    "total_cached_tokens": .number(3)
                ]]
            ]
        ])

        var text = ""
        var reasoning = ""
        var usage = Usage()
        var metadata: JSONValue?
        for part in parts {
            switch part {
            case .textDelta(let delta): text += delta
            case .reasoningDelta(let delta): reasoning += delta
            case .providerMetadata(let value): metadata = value
            case .finish(_, let value): usage = value
            default: break
            }
        }

        XCTAssertEqual(text, "Hello world")
        XCTAssertEqual(reasoning, "thinking", "thought steps must surface as reasoning")
        XCTAssertEqual(metadata?["google"]?["interactionId"], "v1_abc")
        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.reasoningTokens, 22)
        XCTAssertEqual(usage.cachedInputTokens, 3)
    }

    func testFunctionCallStepsBecomeToolCalls() {
        let parts = decode([
            ["event_type": "interaction.created", "interaction": ["id": "v1_abc"]],
            [
                "event_type": "step.start", "index": .number(0),
                "step": ["type": "function_call", "id": "call_1", "name": "weather"]
            ],
            [
                "event_type": "step.delta", "index": .number(0),
                "delta": ["type": "arguments", "arguments": "{\"city\":"]
            ],
            [
                "event_type": "step.delta", "index": .number(0),
                "delta": ["type": "arguments", "arguments": "\"SF\"}"]
            ],
            ["event_type": "step.stop", "index": .number(0)],
            ["event_type": "interaction.completed", "interaction": ["id": "v1_abc"]]
        ])

        var started: String?
        var call: ToolCall?
        var fragments = ""
        for part in parts {
            switch part {
            case .toolCallStart(_, let name): started = name
            case .toolArgumentsDelta(_, let partial): fragments += partial
            case .toolCall(let value): call = value
            default: break
            }
        }

        XCTAssertEqual(started, "weather")
        XCTAssertEqual(fragments, "{\"city\":\"SF\"}")
        XCTAssertEqual(call?.id, "call_1")
        XCTAssertEqual(call?.name, "weather")
        XCTAssertEqual(call?.arguments["city"], "SF")
    }

    func testFailedInteractionsFinishWithAnErrorReason() {
        let parts = decode([
            ["event_type": "interaction.created", "interaction": ["id": "v1_abc"]],
            ["event_type": "interaction.failed", "interaction": ["id": "v1_abc"]]
        ])
        guard case .finish(let reason, _)? = parts.last else {
            return XCTFail("expected a finish part")
        }
        XCTAssertEqual(reason, .error)
    }

    func testTruncatedStreamsStillFinish() {
        let parts = decode([
            ["event_type": "step.start", "index": .number(0), "step": ["type": "model_output"]],
            [
                "event_type": "step.delta", "index": .number(0),
                "delta": ["type": "text", "text": "partial"]
            ]
        ])
        XCTAssertTrue(parts.contains { part in
            if case .finish = part { return true }
            return false
        })
    }
}

final class GoogleEmbeddingModelTests: XCTestCase {

    func testSingleTextUsesEmbedContent() async throws {
        StubTransport.reset(response: .object([
            "embedding": .object(["values": .array([.number(0.1), .number(0.2)])]),
            "usageMetadata": .object(["promptTokenCount": .number(4)])
        ]))
        let model = GoogleEmbeddingModel(
            apiKey: "k", taskType: .retrievalDocument, title: "Doc",
            outputDimensionality: 768, urlSession: StubTransport.session()
        )

        let response = try await model.embed(["hello"])
        XCTAssertEqual(response.embeddings, [[0.1, 0.2]])
        XCTAssertEqual(response.usage.inputTokens, 4)

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1beta/models/gemini-embedding-001:embedContent")
        XCTAssertEqual(request.body?["content"]?["parts"]?[0]?["text"], "hello")
        XCTAssertEqual(request.body?["taskType"], "RETRIEVAL_DOCUMENT")
        XCTAssertEqual(request.body?["title"], "Doc")
        XCTAssertEqual(request.body?["outputDimensionality"], .number(768))
    }

    func testMultipleTextsUseBatchEmbedContents() async throws {
        StubTransport.reset(response: .object([
            "embeddings": .array([
                .object(["values": .array([.number(1)])]),
                .object(["values": .array([.number(2)])])
            ])
        ]))
        let model = GoogleEmbeddingModel(apiKey: "k", urlSession: StubTransport.session())
        let response = try await model.embed(["a", "b"])

        XCTAssertEqual(response.embeddings, [[1], [2]])
        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1beta/models/gemini-embedding-001:batchEmbedContents")
        XCTAssertEqual(request.body?["requests"]?.arrayValue?.count, 2)
        XCTAssertEqual(request.body?["requests"]?[0]?["model"], "models/gemini-embedding-001")
    }

    func testAPIKeyRidesTheGoogleHeader() async throws {
        StubTransport.reset(response: .object([
            "embedding": .object(["values": .array([.number(1)])])
        ]))
        let model = GoogleEmbeddingModel(apiKey: "secret", urlSession: StubTransport.session())
        _ = try await model.embed(["x"])
        XCTAssertNil(StubTransport.requests.first?.authorization)
    }
}

final class GooglePlatformClientTests: XCTestCase {

    func testCachedContentLifecycle() async throws {
        StubTransport.reset(response: .object(["name": "cachedContents/abc"]))
        let cache = GoogleCachedContentClient(apiKey: "k", urlSession: StubTransport.session())

        let name = try await cache.create(
            model: "gemini-3.5-flash",
            messages: [.user("A long transcript")],
            systemInstruction: "Summarize on request",
            ttlSeconds: 300,
            displayName: "transcript"
        )
        XCTAssertEqual(name, "cachedContents/abc")

        _ = try await cache.updateTTL(name, ttlSeconds: 600)
        _ = try await cache.delete(name)

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].path, "/v1beta/cachedContents")
        XCTAssertEqual(recorded[0].body?["model"], "models/gemini-3.5-flash")
        XCTAssertEqual(recorded[0].body?["ttl"], "300s")
        XCTAssertEqual(
            recorded[0].body?["systemInstruction"]?["parts"]?[0]?["text"],
            "Summarize on request"
        )

        XCTAssertEqual(recorded[1].method, "PATCH")
        XCTAssertEqual(recorded[1].path, "/v1beta/cachedContents/abc")
        XCTAssertEqual(recorded[1].queryValue("updateMask"), "ttl")

        XCTAssertEqual(recorded[2].method, "DELETE")
    }

    func testBatchGenerateContentAndEmbeddings() async throws {
        StubTransport.reset(response: .object(["name": "batches/xyz"]))
        let batches = GoogleBatchClient(apiKey: "k", urlSession: StubTransport.session())

        let name = try await batches.create(
            model: "gemini-3.6-flash",
            displayName: "nightly",
            requests: [
                .init(key: "request-1", messages: [.user("One")]),
                .init(key: "request-2", messages: [.user("Two")])
            ]
        )
        XCTAssertEqual(name, "batches/xyz")

        _ = try await batches.createEmbeddings(
            model: "gemini-embedding-001", displayName: "vectors", texts: ["a"]
        )
        _ = try await batches.cancel(name)

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].path, "/v1beta/models/gemini-3.6-flash:batchGenerateContent")
        let wrapped = recorded[0].body?["batch"]
        XCTAssertEqual(wrapped?["display_name"], "nightly")
        let requests = wrapped?["input_config"]?["requests"]?["requests"]?.arrayValue
        XCTAssertEqual(requests?.count, 2)
        XCTAssertEqual(requests?[0]["metadata"]?["key"], "request-1")
        XCTAssertNotNil(requests?[0]["request"]?["contents"])

        XCTAssertEqual(
            recorded[1].path, "/v1beta/models/gemini-embedding-001:asyncBatchEmbedContent"
        )
        XCTAssertEqual(recorded[2].path, "/v1beta/batches/xyz:cancel")
    }

    func testCountTokens() async throws {
        StubTransport.reset(response: .object(["totalTokens": .number(11)]))
        let model = GoogleModel(
            "gemini-3.5-flash", apiKey: "k", urlSession: StubTransport.session()
        )
        let total = try await model.countTokens([.user("The quick brown fox")])
        XCTAssertEqual(total, 11)
        XCTAssertEqual(
            StubTransport.requests.first?.path, "/v1beta/models/gemini-3.5-flash:countTokens"
        )
    }

    func testFileResourcePathNormalization() {
        XCTAssertEqual(GoogleFilesClient.resourcePath("abc"), "files/abc")
        XCTAssertEqual(GoogleFilesClient.resourcePath("files/abc"), "files/abc")
    }

    func testFileMetadataDecoding() {
        let wrapped = GoogleFile(.object(["file": .object([
            "name": "files/abc",
            "uri": "https://generativelanguage.googleapis.com/v1beta/files/abc",
            "mimeType": "audio/mpeg",
            "state": "PROCESSING"
        ])]))
        XCTAssertEqual(wrapped?.name, "files/abc")
        XCTAssertEqual(wrapped?.mimeType, "audio/mpeg")
        XCTAssertFalse(wrapped?.isReady ?? true)

        let bare = GoogleFile(.object(["name": "files/xyz", "state": "ACTIVE"]))
        XCTAssertTrue(bare?.isReady ?? false)
        XCTAssertNil(GoogleFile(.object(["uri": "no-name"])))
    }
}

final class GoogleMediaModelTests: XCTestCase {

    func testImagenPredictShape() async throws {
        StubTransport.reset(response: .object([
            "predictions": .array([
                .object(["bytesBase64Encoded": .string(Data([0x1]).base64EncodedString())])
            ])
        ]))
        let model = GoogleImageModel(apiKey: "k", urlSession: StubTransport.session())
        let response = try await model.generateImages(
            ImageModelRequest(prompt: "a robot", n: 2, aspectRatio: "16:9")
        )

        XCTAssertEqual(response.images.count, 1)
        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1beta/models/imagen-4.0-generate-001:predict")
        XCTAssertEqual(request.body?["instances"]?[0]?["prompt"], "a robot")
        XCTAssertEqual(request.body?["parameters"]?["sampleCount"], .number(2))
        XCTAssertEqual(request.body?["parameters"]?["aspectRatio"], "16:9")
    }

    func testVeoRequestBodyAndSampleExtraction() async throws {
        let body = GoogleVideoModel.requestBody(
            VideoModelRequest(prompt: "a sunset", aspectRatio: "16:9", duration: 8)
        )
        XCTAssertEqual(body["instances"]?[0]?["prompt"], "a sunset")
        XCTAssertEqual(body["parameters"]?["durationSeconds"], .number(8))

        let status: JSONValue = .object([
            "done": .bool(true),
            "response": .object([
                "generateVideoResponse": .object([
                    "generatedSamples": .array([
                        .object(["video": .object([
                            "bytesBase64Encoded": .string(Data([0x9]).base64EncodedString())
                        ])])
                    ])
                ])
            ])
        ])
        let http = GoogleHTTP(
            apiKey: "k",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            headers: [:], urlSession: StubTransport.session()
        )
        let response = try await GoogleVideoModel.videos(from: status, http: http)
        XCTAssertEqual(response.videos, [Data([0x9])])
    }

    func testGeminiTTSRequestsAudioModality() {
        let body = GoogleSpeechModel.requestBody(
            SpeechModelRequest(text: "Hello there", voice: "Kore"),
            modelID: "gemini-3.1-flash-tts-preview"
        )
        XCTAssertEqual(
            body["generationConfig"]?["responseModalities"], .array([.string("AUDIO")])
        )
        let voiceConfig = body["generationConfig"]?["speechConfig"]?["voiceConfig"]
        XCTAssertEqual(voiceConfig?["prebuiltVoiceConfig"]?["voiceName"], "Kore")
        XCTAssertEqual(body["contents"]?[0]?["parts"]?[0]?["text"], "Hello there")
    }

    func testLyriaMusicGeneration() async throws {
        StubTransport.reset(response: .object([
            "predictions": .array([
                .object(["bytesBase64Encoded": .string(Data([0x5]).base64EncodedString())])
            ])
        ]))
        let model = GoogleMusicModel(apiKey: "k", urlSession: StubTransport.session())
        let audio = try await model.generateMusic(prompt: "lofi beat", seed: 7)

        XCTAssertEqual(audio, Data([0x5]))
        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1beta/models/lyria-3-clip-preview:predict")
        XCTAssertEqual(request.body?["parameters"]?["seed"], .number(7))
    }
}

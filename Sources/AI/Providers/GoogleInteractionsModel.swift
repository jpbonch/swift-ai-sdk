import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleInteractionsModel: LanguageModel {
    public let provider = "google"
    public let modelID: String

    public enum Target: Sendable, Hashable {
        case model(String)
        case agent(String)

        var id: String {
            switch self {
            case .model(let id), .agent(let id): id
            }
        }

        var field: String {
            switch self {
            case .model: "model"
            case .agent: "agent"
            }
        }
    }

    let target: Target
    let http: GoogleHTTP
    public var previousInteractionID: String?
    public var store: Bool
    public var background: Bool
    public var agentConfig: JSONValue?

    public init(
        _ modelID: String,
        apiKey: String? = nil,
        previousInteractionID: String? = nil,
        store: Bool = false,
        background: Bool = false,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.target = .model(modelID)
        self.modelID = modelID
        self.previousInteractionID = previousInteractionID
        self.store = store
        self.background = background
        self.agentConfig = nil
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public static func agent(
        _ agentID: String,
        apiKey: String? = nil,
        agentConfig: JSONValue? = nil,
        previousInteractionID: String? = nil,
        store: Bool = true,
        background: Bool = false,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) -> GoogleInteractionsModel {
        GoogleInteractionsModel(
            target: .agent(agentID),
            http: GoogleHTTP(
                apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
            ),
            previousInteractionID: previousInteractionID,
            store: store,
            background: background,
            agentConfig: agentConfig
        )
    }

    private init(
        target: Target,
        http: GoogleHTTP,
        previousInteractionID: String?,
        store: Bool,
        background: Bool,
        agentConfig: JSONValue?
    ) {
        self.target = target
        self.modelID = target.id
        self.http = http
        self.previousInteractionID = previousInteractionID
        self.store = store
        self.background = background
        self.agentConfig = agentConfig
    }

    public func stream(
        _ request: LanguageModelRequest
    ) async throws -> AsyncThrowingStream<StreamPart, Error> {
        var urlRequest = http.request("POST", "interactions", query: ["alt": "sse"])
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(requestBody(for: request, stream: true))

        let (bytes, response) = try await http.urlSession.bytes(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIError.http(status: httpResponse.statusCode, body: body)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = InteractionStreamDecoder()
                do {
                    for try await event in SSE.events(from: bytes) {
                        guard let data = event.data.data(using: .utf8),
                              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                        else { continue }
                        for part in decoder.consume(value) { continuation.yield(part) }
                    }
                    for part in decoder.finish() { continuation.yield(part) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func create(_ request: LanguageModelRequest) async throws -> JSONValue {
        try await http.send(
            "POST", "interactions", json: requestBody(for: request, stream: false)
        )
    }

    public func retrieve(_ interactionID: String) async throws -> JSONValue {
        try await http.send("GET", "interactions/\(interactionID)")
    }

    @discardableResult
    public func cancel(_ interactionID: String) async throws -> JSONValue {
        try await http.send("POST", "interactions/\(interactionID):cancel", json: .object([:]))
    }

    @discardableResult
    public func delete(_ interactionID: String) async throws -> Bool {
        _ = try await http.send("DELETE", "interactions/\(interactionID)")
        return true
    }

    func requestBody(for request: LanguageModelRequest, stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            target.field: .string(target.id),
            "input": .array(Self.inputSteps(request.messages))
        ]
        if stream { body["stream"] = .bool(true) }
        if store { body["store"] = .bool(true) } else { body["store"] = .bool(false) }
        if background { body["background"] = .bool(true) }
        if let previousInteractionID {
            body["previous_interaction_id"] = .string(previousInteractionID)
        }
        if let system = Self.systemInstruction(request.messages) {
            body["system_instruction"] = .string(system)
        }

        let tools = Self.toolDeclarations(request)
        if !tools.isEmpty { body["tools"] = .array(tools) }

        if case .json(let schema, _, _) = request.responseFormat {
            body["response_json_schema"] = schema
        }

        if let agentConfig {
            body["agent_config"] = agentConfig
        } else {
            var generation: [String: JSONValue] = [
                "max_output_tokens": .number(Double(request.maxOutputTokens))
            ]
            if let temperature = request.temperature {
                generation["temperature"] = .number(temperature)
            }
            if let topP = request.topP { generation["top_p"] = .number(topP) }
            if let seed = request.seed { generation["seed"] = .number(Double(seed)) }
            if !request.stopSequences.isEmpty {
                generation["stop_sequences"] = .array(request.stopSequences.map { .string($0) })
            }
            if let level = Self.thinkingLevel(request.reasoning) {
                generation["thinking_level"] = .string(level)
            }
            switch request.toolChoice {
            case .auto: break
            case .none: generation["tool_choice"] = .string("none")
            case .required: generation["tool_choice"] = .string("any")
            case .tool: generation["tool_choice"] = .string("validated")
            }
            if case .object(let options)? = request.providerOptions {
                for (key, value) in options {
                    if key == "agent_config" || key == "tools" || key == "input" {
                        body[key] = value
                    } else {
                        generation[key] = value
                    }
                }
            }
            body["generation_config"] = .object(generation)
        }

        return .object(body)
    }

    static func thinkingLevel(_ reasoning: ReasoningEffort) -> String? {
        guard reasoning.isCustom else { return nil }
        switch reasoning {
        case .none, .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh: return "high"
        default: return nil
        }
    }

    static func systemInstruction(_ messages: [Message]) -> String? {
        let system = messages.filter { $0.role == .system }.map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return system.isEmpty ? nil : system
    }

    static func toolDeclarations(_ request: LanguageModelRequest) -> [JSONValue] {
        var tools: [JSONValue] = request.functionTools.map { tool in
            .object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters
            ])
        }
        tools.append(contentsOf: request.providerToolEntries(for: "google"))
        return tools
    }

    static func inputSteps(_ messages: [Message]) -> [JSONValue] {
        var steps: [JSONValue] = []
        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                let content = message.content.compactMap(contentPart)
                guard !content.isEmpty else { continue }
                steps.append(.object([
                    "type": .string("user_input"),
                    "content": .array(content)
                ]))

            case .assistant:
                for part in message.content {
                    switch part {
                    case .text(let text) where !text.isEmpty:
                        steps.append(.object([
                            "type": .string("model_output"),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(text)])
                            ])
                        ]))
                    case .toolCall(let call):
                        steps.append(.object([
                            "type": .string("function_call"),
                            "id": .string(call.id),
                            "name": .string(call.name),
                            "arguments": call.arguments
                        ]))
                    default:
                        continue
                    }
                }

            case .tool:
                for part in message.content {
                    guard case .toolResult(let result) = part else { continue }
                    steps.append(.object([
                        "type": .string("function_result"),
                        "name": .string(result.name),
                        "call_id": .string(result.toolCallID),
                        "result": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(Self.stringify(result.output))
                            ])
                        ])
                    ]))
                }

            case .system:
                continue
            }
        }
        return steps
    }

    static func contentPart(_ part: ContentPart) -> JSONValue? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : .object([
                "type": .string("text"), "text": .string(text)
            ])
        case .image(let image):
            if let uri = image.url?.absoluteString {
                return .object([
                    "type": .string("image"),
                    "uri": .string(uri),
                    "mime_type": .string(image.mediaType ?? "image/png")
                ])
            }
            guard let data = image.data else { return nil }
            return .object([
                "type": .string("image"),
                "data": .string(data.base64EncodedString()),
                "mime_type": .string(image.mediaType ?? "image/png")
            ])
        case .file(let file):
            let kind = Self.partType(for: file.mediaType)
            if let uri = file.url?.absoluteString {
                return .object([
                    "type": .string(kind),
                    "uri": .string(uri),
                    "mime_type": .string(file.mediaType)
                ])
            }
            guard let data = file.data else { return nil }
            return .object([
                "type": .string(kind),
                "data": .string(data.base64EncodedString()),
                "mime_type": .string(file.mediaType)
            ])
        case .toolCall, .toolResult, .toolApprovalResponse:
            return nil
        }
    }

    static func partType(for mediaType: String) -> String {
        if mediaType.hasPrefix("image/") { return "image" }
        if mediaType.hasPrefix("audio/") { return "audio" }
        if mediaType.hasPrefix("video/") { return "video" }
        return "file"
    }

    static func stringify(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

struct InteractionStreamDecoder {
    private var stepTypes: [Int: String] = [:]
    private var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var usage = Usage()
    private var finishReason: FinishReason = .stop
    private var finished = false
    private var interactionID: String?
    private var sawToolCall = false

    mutating func consume(_ event: JSONValue) -> [StreamPart] {
        switch event["event_type"]?.stringValue {
        case "interaction.created":
            interactionID = event["interaction"]?["id"]?.stringValue
            guard let id = interactionID else { return [] }
            return [.providerMetadata(.object([
                "google": .object(["interactionId": .string(id)])
            ]))]

        case "step.start":
            guard let index = event["index"]?.intValue else { return [] }
            let type = event["step"]?["type"]?.stringValue ?? ""
            stepTypes[index] = type
            if type == "function_call" {
                let id = event["step"]?["id"]?.stringValue ?? "call-\(index)"
                let name = event["step"]?["name"]?.stringValue ?? ""
                toolCalls[index] = (id: id, name: name, arguments: "")
                return name.isEmpty ? [] : [.toolCallStart(id: id, name: name)]
            }
            return []

        case "step.delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
                if stepTypes[index] == "thought" { return [.reasoningDelta(text)] }
                return [.textDelta(text)]
            case "thought_text", "thought_summary":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
                return [.reasoningDelta(text)]
            case "arguments", "function_call_arguments":
                guard var call = toolCalls[index] else { return [] }
                let fragment = delta["arguments"]?.stringValue ?? delta["text"]?.stringValue ?? ""
                guard !fragment.isEmpty else { return [] }
                call.arguments += fragment
                toolCalls[index] = call
                return [.toolArgumentsDelta(id: call.id, partialJSON: fragment)]
            default:
                return []
            }

        case "step.stop":
            guard let index = event["index"]?.intValue else { return [] }
            guard let call = toolCalls.removeValue(forKey: index) else { return [] }
            sawToolCall = true
            let name = call.name.isEmpty
                ? event["step"]?["name"]?.stringValue ?? ""
                : call.name
            let arguments = Self.parse(call.arguments)
                ?? event["step"]?["arguments"]
                ?? .object([:])
            return [.toolCall(ToolCall(id: call.id, name: name, arguments: arguments))]

        case "interaction.completed", "interaction.failed", "interaction.cancelled":
            finished = true
            if let usageValue = event["interaction"]?["usage"] {
                usage = Self.usage(from: usageValue)
            }
            if event["event_type"]?.stringValue != "interaction.completed" {
                finishReason = .error
            } else if sawToolCall || !toolCalls.isEmpty {
                // `step.stop` removes each call as it completes, so asking
                // whether any are still open would only ever be true for a
                // dangling one.
                finishReason = .toolCalls
            }
            return [.finish(reason: finishReason, usage: usage)]

        default:
            return []
        }
    }

    mutating func finish() -> [StreamPart] {
        guard !finished else { return [] }
        finished = true
        return [.finish(reason: finishReason, usage: usage)]
    }

    static func usage(from value: JSONValue) -> Usage {
        Usage(
            inputTokens: value["total_input_tokens"]?.intValue ?? 0,
            outputTokens: value["total_output_tokens"]?.intValue ?? 0,
            cachedInputTokens: value["total_cached_tokens"]?.intValue,
            reasoningTokens: value["total_thought_tokens"]?.intValue
        )
    }

    static func parse(_ json: String) -> JSONValue? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

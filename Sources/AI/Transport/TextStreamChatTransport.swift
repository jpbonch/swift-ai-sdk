import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TextStreamChatTransport: ChatTransport {
    public var api: URL
    public var headers: [String: String]
    public var body: JSONValue?
    private let urlSession: URLSession

    public init(
        api: URL,
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        urlSession: URLSession = .shared
    ) {
        self.api = api
        self.headers = headers
        self.body = body
        self.urlSession = urlSession
    }

    public func sendMessages(
        _ request: ChatRequest
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        var urlRequest = URLRequest(url: api)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }

        var payload: [String: JSONValue] = [
            "id": .string(request.chatID),
            "messages": .array(request.messages.map(\.wire)),
            "trigger": .string(request.trigger.rawValue)
        ]
        if let messageID = request.messageID { payload["messageId"] = .string(messageID) }
        if case .object(let extra)? = body {
            for (key, value) in extra { payload[key] = value }
        }
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(payload))

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw AIError.http(status: http.statusCode, body: errorBody)
        }

        let messageID = UUID().uuidString
        return AsyncThrowingStream { continuation in
            let task = Task {
                let textID = "text-0"
                continuation.yield(.start(messageID: messageID))
                continuation.yield(.textStart(id: textID))
                do {
                    for try await line in bytes.lines {
                        continuation.yield(.textDelta(id: textID, delta: line))
                    }
                    continuation.yield(.textEnd(id: textID))
                    continuation.yield(.finish(finishReason: .stop))
                    continuation.finish()
                } catch {
                    continuation.yield(.textEnd(id: textID))
                    continuation.yield(.error(errorText: "\(error)"))
                    continuation.yield(.finish(finishReason: .error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public func consumeStream(
    _ chunks: AsyncThrowingStream<UIMessageChunk, Error>,
    onError: (@Sendable (Error) async -> Void)? = nil
) async {
    do {
        for try await _ in chunks {}
    } catch {
        await onError?(error)
    }
}

public func consumeStream(
    _ parts: AsyncThrowingStream<TextStreamPart, Error>,
    onError: (@Sendable (Error) async -> Void)? = nil
) async {
    do {
        for try await _ in parts {}
    } catch {
        await onError?(error)
    }
}

public extension StreamTextResult {
    func consumeStream(onError: (@Sendable (Error) async -> Void)? = nil) async {
        await AI.consumeStream(fullStream, onError: onError)
    }
}

public enum UIMessageValidation {

    public static func validate(_ messages: [UIMessage]) throws -> [UIMessage] {
        for message in messages {
            for part in message.parts {
                guard case .tool(let tool) = part else { continue }
                if tool.toolCallID.isEmpty {
                    throw AIError.invalidRequest(
                        "UIMessage \(message.id) has a tool part without a toolCallId"
                    )
                }
                switch tool.state {
                case .approvalRequested, .approvalResponded:
                    if tool.approval == nil {
                        throw AIError.invalidRequest(
                            "UIMessage \(message.id) has a tool part in state "
                            + "\(tool.state.rawValue) without approval metadata"
                        )
                    }
                case .outputAvailable:
                    if tool.output == nil {
                        throw AIError.invalidRequest(
                            "UIMessage \(message.id) has an output-available tool part "
                            + "without output"
                        )
                    }
                default:
                    continue
                }
            }
        }
        return messages
    }

    public static func safeValidate(_ messages: [UIMessage]) -> Result<[UIMessage], Error> {
        Result { try validate(messages) }
    }
}

public func validateUIMessages(_ messages: [UIMessage]) throws -> [UIMessage] {
    try UIMessageValidation.validate(messages)
}

public func safeValidateUIMessages(_ messages: [UIMessage]) -> Result<[UIMessage], Error> {
    UIMessageValidation.safeValidate(messages)
}

public func lastAssistantMessageIsCompleteWithToolCalls(_ messages: [UIMessage]) -> Bool {
    guard let message = messages.last, message.role == .assistant else { return false }
    let toolParts = message.parts.compactMap { part -> ToolUIPart? in
        if case .tool(let tool) = part { return tool }
        return nil
    }
    guard !toolParts.isEmpty else { return false }
    return toolParts.allSatisfy {
        $0.state == .outputAvailable || $0.state == .outputError || $0.state == .outputDenied
    }
}

public func lastAssistantMessageIsCompleteWithApprovalResponses(_ messages: [UIMessage]) -> Bool {
    guard let message = messages.last, message.role == .assistant else { return false }
    let awaiting = message.parts.compactMap { part -> ToolUIPart? in
        if case .tool(let tool) = part, tool.state == .approvalRequested { return tool }
        return nil
    }
    guard awaiting.isEmpty else { return false }
    return message.parts.contains { part in
        if case .tool(let tool) = part { return tool.state == .approvalResponded }
        return false
    }
}

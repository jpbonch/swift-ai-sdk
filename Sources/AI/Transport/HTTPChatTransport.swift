import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PreparedChatRequest: Sendable {
    public var api: URL?
    public var headers: [String: String]
    public var body: JSONValue?

    public init(
        api: URL? = nil,
        headers: [String: String] = [:],
        body: JSONValue? = nil
    ) {
        self.api = api
        self.headers = headers
        self.body = body
    }
}

public struct HTTPChatTransport: ChatTransport {
    public var api: URL
    public var headers: [String: String]
    public var body: JSONValue?
    public var prepareSendMessagesRequest:
        (@Sendable (ChatRequest) async throws -> PreparedChatRequest)?
    public var prepareReconnectToStreamRequest:
        (@Sendable (String) async throws -> PreparedChatRequest)?
    private let urlSession: URLSession

    public init(
        api: URL,
        headers: [String: String] = [:],
        body: JSONValue? = nil,
        prepareSendMessagesRequest:
            (@Sendable (ChatRequest) async throws -> PreparedChatRequest)? = nil,
        prepareReconnectToStreamRequest:
            (@Sendable (String) async throws -> PreparedChatRequest)? = nil,
        urlSession: URLSession = .shared
    ) {
        self.api = api
        self.headers = headers
        self.body = body
        self.prepareSendMessagesRequest = prepareSendMessagesRequest
        self.prepareReconnectToStreamRequest = prepareReconnectToStreamRequest
        self.urlSession = urlSession
    }

    public func sendMessages(
        _ request: ChatRequest
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        let prepared = try await prepareSendMessagesRequest?(request)

        var urlRequest = URLRequest(url: prepared?.api ?? api)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in prepared?.headers ?? [:] {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        var payload: [String: JSONValue] = [:]
        if case .object(let extra)? = body {
            for (key, value) in extra { payload[key] = value }
        }
        payload["id"] = .string(request.chatID)
        payload["messages"] = .array(request.messages.map(\.wire))
        payload["trigger"] = .string(request.trigger.rawValue)
        if let messageID = request.messageID { payload["messageId"] = .string(messageID) }
        if case .object(let overrides)? = prepared?.body {
            for (key, value) in overrides { payload[key] = value }
        }
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(payload))

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw AIError.http(status: http.statusCode, body: errorBody)
        }

        return Self.chunkStream(from: bytes)
    }

    public func reconnectToStream(
        chatID: String
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error>? {
        let prepared = try await prepareReconnectToStreamRequest?(chatID)
        var urlRequest = URLRequest(
            url: prepared?.api
                ?? api.appendingPathComponent(chatID).appendingPathComponent("stream")
        )
        urlRequest.httpMethod = "GET"
        for (field, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in prepared?.headers ?? [:] {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 204 { return nil }
            if !(200..<300).contains(http.statusCode) {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                throw AIError.http(status: http.statusCode, body: errorBody)
            }
        }
        return Self.chunkStream(from: bytes)
    }

    static func chunkStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<UIMessageChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    loop: for try await event in SSE.events(from: bytes) {
                        switch Self.decodeChunk(event.data) {
                        case .chunk(let chunk): continuation.yield(chunk)
                        case .done: break loop
                        case .skipped: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum DecodedEvent {
        case chunk(UIMessageChunk)
        case done
        case skipped
    }

    static func decodeChunk(_ data: String) -> DecodedEvent {
        if data == "[DONE]" { return .done }
        guard let bytes = data.data(using: .utf8),
              let wire = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let chunk = UIMessageChunk(wire: wire)
        else { return .skipped }
        return .chunk(chunk)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OpenAIHTTP: Sendable {
    var apiKey: String
    var baseURL: URL
    var headers: [String: String]
    var urlSession: URLSession

    init(apiKey: String?, baseURL: URL, headers: [String: String], urlSession: URLSession) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        self.baseURL = baseURL
        self.headers = headers
        self.urlSession = urlSession
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        let base = baseURL.appendingPathComponent(path)
        var url = base
        if !query.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? base
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    func send(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        query: [String: String] = [:]
    ) async throws -> JSONValue {
        var urlRequest = request(method, path, query: query)
        if let json {
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.httpBody = try JSONEncoder().encode(json)
        }
        let (data, response) = try await urlSession.data(for: urlRequest)
        try Self.check(response, data)
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func download(_ path: String) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request("GET", path))
        try Self.check(response, data)
        return data
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

public struct OpenAIConversationsClient: Sendable {
    let http: OpenAIHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        items: [JSONValue] = [],
        metadata: JSONValue? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = [:]
        if !items.isEmpty { body["items"] = .array(items) }
        if let metadata { body["metadata"] = metadata }
        let json = try await http.send("POST", "conversations", json: .object(body))
        guard let id = json["id"]?.stringValue else {
            throw AIError.decoding("OpenAI conversation create returned no id")
        }
        return id
    }

    public func createFromMessages(
        _ messages: [Message], metadata: JSONValue? = nil
    ) async throws -> String {
        let items = messages.compactMap { message -> JSONValue? in
            let text = message.text
            guard !text.isEmpty, message.role != .tool else { return nil }
            let role: String = switch message.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system, .tool: "system"
            }
            return .object(["role": .string(role), "content": .string(text)])
        }
        return try await create(items: items, metadata: metadata)
    }

    public func get(_ conversationID: String) async throws -> JSONValue {
        try await http.send("GET", "conversations/\(conversationID)")
    }

    @discardableResult
    public func update(
        _ conversationID: String, metadata: JSONValue
    ) async throws -> JSONValue {
        try await http.send(
            "POST", "conversations/\(conversationID)",
            json: .object(["metadata": metadata])
        )
    }

    @discardableResult
    public func delete(_ conversationID: String) async throws -> Bool {
        let json = try await http.send("DELETE", "conversations/\(conversationID)")
        return json["deleted"]?.boolValue ?? true
    }

    public func items(
        _ conversationID: String, limit: Int? = nil, after: String? = nil, order: String? = nil
    ) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let after { query["after"] = after }
        if let order { query["order"] = order }
        return try await http.send(
            "GET", "conversations/\(conversationID)/items", query: query
        )
    }

    @discardableResult
    public func addItems(
        _ conversationID: String, items: [JSONValue]
    ) async throws -> JSONValue {
        try await http.send(
            "POST", "conversations/\(conversationID)/items",
            json: .object(["items": .array(items)])
        )
    }

    @discardableResult
    public func deleteItem(
        _ conversationID: String, itemID: String
    ) async throws -> Bool {
        _ = try await http.send("DELETE", "conversations/\(conversationID)/items/\(itemID)")
        return true
    }
}

public struct OpenAIVectorStoresClient: Sendable {
    let http: OpenAIHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        name: String? = nil,
        fileIDs: [String] = [],
        expiresAfterDays: Int? = nil,
        chunkingStrategy: JSONValue? = nil,
        metadata: JSONValue? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if !fileIDs.isEmpty { body["file_ids"] = .array(fileIDs.map { .string($0) }) }
        if let expiresAfterDays {
            body["expires_after"] = .object([
                "anchor": .string("last_active_at"),
                "days": .number(Double(expiresAfterDays))
            ])
        }
        if let chunkingStrategy { body["chunking_strategy"] = chunkingStrategy }
        if let metadata { body["metadata"] = metadata }

        let json = try await http.send("POST", "vector_stores", json: .object(body))
        guard let id = json["id"]?.stringValue else {
            throw AIError.decoding("OpenAI vector store create returned no id")
        }
        return id
    }

    public func list(limit: Int? = nil, after: String? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let after { query["after"] = after }
        return try await http.send("GET", "vector_stores", query: query)
    }

    public func get(_ storeID: String) async throws -> JSONValue {
        try await http.send("GET", "vector_stores/\(storeID)")
    }

    @discardableResult
    public func update(
        _ storeID: String, name: String? = nil, metadata: JSONValue? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let metadata { body["metadata"] = metadata }
        return try await http.send("POST", "vector_stores/\(storeID)", json: .object(body))
    }

    @discardableResult
    public func delete(_ storeID: String) async throws -> Bool {
        let json = try await http.send("DELETE", "vector_stores/\(storeID)")
        return json["deleted"]?.boolValue ?? true
    }

    public func search(
        _ storeID: String,
        query: String,
        maxResults: Int? = nil,
        filters: JSONValue? = nil,
        rewriteQuery: Bool? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = ["query": .string(query)]
        if let maxResults { body["max_num_results"] = .number(Double(maxResults)) }
        if let filters { body["filters"] = filters }
        if let rewriteQuery { body["rewrite_query"] = .bool(rewriteQuery) }
        return try await http.send(
            "POST", "vector_stores/\(storeID)/search", json: .object(body)
        )
    }

    @discardableResult
    public func addFile(
        _ storeID: String, fileID: String, attributes: JSONValue? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = ["file_id": .string(fileID)]
        if let attributes { body["attributes"] = attributes }
        return try await http.send(
            "POST", "vector_stores/\(storeID)/files", json: .object(body)
        )
    }

    public func files(_ storeID: String, limit: Int? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        return try await http.send("GET", "vector_stores/\(storeID)/files", query: query)
    }

    @discardableResult
    public func removeFile(_ storeID: String, fileID: String) async throws -> Bool {
        let json = try await http.send("DELETE", "vector_stores/\(storeID)/files/\(fileID)")
        return json["deleted"]?.boolValue ?? true
    }
}

public struct OpenAIBatchClient: Sendable {
    let http: OpenAIHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        inputFileID: String,
        endpoint: String = "/v1/responses",
        completionWindow: String = "24h",
        metadata: JSONValue? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = [
            "input_file_id": .string(inputFileID),
            "endpoint": .string(endpoint),
            "completion_window": .string(completionWindow)
        ]
        if let metadata { body["metadata"] = metadata }
        let json = try await http.send("POST", "batches", json: .object(body))
        guard let id = json["id"]?.stringValue else {
            throw AIError.decoding("OpenAI batch create returned no id")
        }
        return id
    }

    public func list(limit: Int? = nil, after: String? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let after { query["after"] = after }
        return try await http.send("GET", "batches", query: query)
    }

    public func get(_ batchID: String) async throws -> JSONValue {
        try await http.send("GET", "batches/\(batchID)")
    }

    @discardableResult
    public func cancel(_ batchID: String) async throws -> JSONValue {
        try await http.send("POST", "batches/\(batchID)/cancel", json: .object([:]))
    }
}

public struct OpenAIContainersClient: Sendable {
    let http: OpenAIHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        name: String,
        fileIDs: [String] = [],
        expiresAfterMinutes: Int? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = ["name": .string(name)]
        if !fileIDs.isEmpty { body["file_ids"] = .array(fileIDs.map { .string($0) }) }
        if let expiresAfterMinutes {
            body["expires_after"] = .object([
                "anchor": .string("last_active_at"),
                "minutes": .number(Double(expiresAfterMinutes))
            ])
        }
        let json = try await http.send("POST", "containers", json: .object(body))
        guard let id = json["id"]?.stringValue else {
            throw AIError.decoding("OpenAI container create returned no id")
        }
        return id
    }

    public func list(limit: Int? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        return try await http.send("GET", "containers", query: query)
    }

    public func get(_ containerID: String) async throws -> JSONValue {
        try await http.send("GET", "containers/\(containerID)")
    }

    @discardableResult
    public func delete(_ containerID: String) async throws -> Bool {
        _ = try await http.send("DELETE", "containers/\(containerID)")
        return true
    }
}

public struct OpenAIModerationsClient: Sendable {
    let http: OpenAIHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public struct Verdict: Sendable {
        public var flagged: Bool
        public var categories: [String]
        public var raw: JSONValue
    }

    public func moderate(
        _ text: String, model: String = "omni-moderation-latest"
    ) async throws -> Verdict {
        try await moderate(input: .string(text), model: model)
    }

    public func moderate(
        input: JSONValue, model: String = "omni-moderation-latest"
    ) async throws -> Verdict {
        let json = try await http.send(
            "POST", "moderations",
            json: .object(["model": .string(model), "input": input])
        )
        guard let result = json["results"]?.arrayValue?.first else {
            throw AIError.decoding("OpenAI moderations returned no results")
        }
        let flaggedCategories = (result["categories"]?.objectValue ?? [:])
            .filter { $0.value.boolValue == true }
            .keys
            .sorted()
        return Verdict(
            flagged: result["flagged"]?.boolValue ?? false,
            categories: Array(flaggedCategories),
            raw: result
        )
    }
}

public struct OpenAIVideoModel: VideoModel {
    public let provider = "openai"
    public let modelID: String

    let http: OpenAIHTTP
    private let pollInterval: Duration
    private let pollTimeout: Duration

    public init(
        _ modelID: String = "sora-2",
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        pollInterval: Duration = .seconds(5),
        pollTimeout: Duration = .seconds(900),
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.http = OpenAIHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func generateVideos(_ request: VideoModelRequest) async throws -> VideoModelResponse {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "prompt": .string(request.prompt)
        ]
        if let seconds = request.duration { body["seconds"] = .string("\(seconds)") }
        if let aspectRatio = request.aspectRatio { body["size"] = .string(aspectRatio) }
        if case .object(let options)? = request.providerOptions {
            for (key, value) in options { body[key] = value }
        }

        let created = try await http.send("POST", "videos", json: .object(body))
        guard let id = created["id"]?.stringValue else {
            throw AIError.decoding("OpenAI video create returned no id")
        }

        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while true {
            let status = try await http.send("GET", "videos/\(id)")
            switch status["status"]?.stringValue {
            case "completed":
                return VideoModelResponse(videos: [try await http.download("videos/\(id)/content")])
            case "failed":
                throw AIError.transport("OpenAI video generation failed: \(status)")
            default:
                guard ContinuousClock.now < deadline else {
                    throw AIError.transport(
                        "OpenAI video generation timed out after \(pollTimeout)"
                    )
                }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    public func remix(_ videoID: String, prompt: String) async throws -> JSONValue {
        try await http.send(
            "POST", "videos/\(videoID)/remix", json: .object(["prompt": .string(prompt)])
        )
    }

    public func list(limit: Int? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        return try await http.send("GET", "videos", query: query)
    }

    @discardableResult
    public func delete(_ videoID: String) async throws -> Bool {
        _ = try await http.send("DELETE", "videos/\(videoID)")
        return true
    }
}

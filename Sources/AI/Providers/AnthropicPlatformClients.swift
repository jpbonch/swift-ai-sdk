import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicHTTP: Sendable {
    var apiKey: String
    var baseURL: URL
    var anthropicVersion: String
    var headers: [String: String]
    var urlSession: URLSession

    init(
        apiKey: String?,
        baseURL: URL,
        anthropicVersion: String,
        headers: [String: String],
        urlSession: URLSession
    ) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.headers = headers
        self.urlSession = urlSession
    }

    func request(
        _ method: String, _ path: String, query: [String: String] = [:], beta: [String] = []
    ) -> URLRequest {
        let base = baseURL.appendingPathComponent(path)
        var url = base
        if !query.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? base
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if !beta.isEmpty {
            request.setValue(beta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    func send(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        query: [String: String] = [:],
        beta: [String] = []
    ) async throws -> JSONValue {
        var urlRequest = request(method, path, query: query, beta: beta)
        if let json {
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.httpBody = try JSONEncoder().encode(json)
        }
        let (data, response) = try await urlSession.data(for: urlRequest)
        try Self.check(response, data)
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func lines(
        _ method: String, _ path: String, beta: [String] = []
    ) async throws -> [JSONValue] {
        let (bytes, response) = try await urlSession.bytes(
            for: request(method, path, beta: beta)
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIError.http(status: http.statusCode, body: body)
        }
        var results: [JSONValue] = []
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            results.append(value)
        }
        return results
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

public struct AnthropicBatchClient: Sendable {
    let http: AnthropicHTTP

    public struct Request: Sendable {
        public var customID: String
        public var params: JSONValue

        public init(customID: String, params: JSONValue) {
            self.customID = customID
            self.params = params
        }

        public init(
            customID: String,
            model: String,
            messages: [Message],
            maxOutputTokens: Int = 1024,
            system: String? = nil
        ) {
            var request = LanguageModelRequest(
                messages: messages, maxOutputTokens: maxOutputTokens
            )
            if let system {
                request.messages = [.system(system)] + messages
            }
            var params = AnthropicModel.requestBody(for: request, modelID: model)
                .objectValue ?? [:]
            params["stream"] = nil
            self.customID = customID
            self.params = .object(params)
        }

        var wire: JSONValue {
            .object(["custom_id": .string(customID), "params": params])
        }
    }

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        anthropicVersion: String = "2023-06-01",
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = AnthropicHTTP(
            apiKey: apiKey, baseURL: baseURL, anthropicVersion: anthropicVersion,
            headers: headers, urlSession: urlSession
        )
    }

    public func create(_ requests: [Request]) async throws -> String {
        let json = try await http.send(
            "POST", "messages/batches",
            json: .object(["requests": .array(requests.map(\.wire))])
        )
        guard let id = json["id"]?.stringValue else {
            throw AIError.decoding("Anthropic batch create returned no id")
        }
        return id
    }

    public func list(
        limit: Int? = nil, beforeID: String? = nil, afterID: String? = nil
    ) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let beforeID { query["before_id"] = beforeID }
        if let afterID { query["after_id"] = afterID }
        return try await http.send("GET", "messages/batches", query: query)
    }

    public func get(_ batchID: String) async throws -> JSONValue {
        try await http.send("GET", "messages/batches/\(batchID)")
    }

    public func results(_ batchID: String) async throws -> [JSONValue] {
        try await http.lines("GET", "messages/batches/\(batchID)/results")
    }

    @discardableResult
    public func cancel(_ batchID: String) async throws -> JSONValue {
        try await http.send("POST", "messages/batches/\(batchID)/cancel", json: .object([:]))
    }

    @discardableResult
    public func delete(_ batchID: String) async throws -> Bool {
        _ = try await http.send("DELETE", "messages/batches/\(batchID)")
        return true
    }
}

public struct AnthropicModelsClient: Sendable {
    let http: AnthropicHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        anthropicVersion: String = "2023-06-01",
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = AnthropicHTTP(
            apiKey: apiKey, baseURL: baseURL, anthropicVersion: anthropicVersion,
            headers: headers, urlSession: urlSession
        )
    }

    public func list(
        limit: Int? = nil, beforeID: String? = nil, afterID: String? = nil
    ) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let beforeID { query["before_id"] = beforeID }
        if let afterID { query["after_id"] = afterID }
        return try await http.send("GET", "models", query: query)
    }

    public func get(_ modelID: String) async throws -> JSONValue {
        try await http.send("GET", "models/\(modelID)")
    }
}

public extension AnthropicModel {
    func countTokens(
        _ messages: [Message],
        tools: [any AIToolProtocol] = [],
        system: String? = nil
    ) async throws -> Int {
        var request = LanguageModelRequest(messages: messages, tools: tools)
        if let system { request.messages = [.system(system)] + messages }
        var body = Self.requestBody(for: request, modelID: modelID).objectValue ?? [:]
        body["stream"] = nil
        body["max_tokens"] = nil

        let http = AnthropicHTTP(
            apiKey: apiKey, baseURL: baseURL, anthropicVersion: anthropicVersion,
            headers: headers, urlSession: urlSession
        )
        let json = try await http.send(
            "POST", "messages/count_tokens",
            json: .object(body),
            beta: Self.betaFlags(for: request)
        )
        return json["input_tokens"]?.intValue ?? 0
    }
}

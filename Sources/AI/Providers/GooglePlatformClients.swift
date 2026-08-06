import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GoogleHTTP: Sendable {
    var apiKey: String
    var baseURL: URL
    var headers: [String: String]
    var urlSession: URLSession

    init(apiKey: String?, baseURL: URL, headers: [String: String], urlSession: URLSession) {
        self.apiKey = apiKey
            ?? ProcessInfo.processInfo.environment["GOOGLE_GENERATIVE_AI_API_KEY"]
            ?? ""
        self.baseURL = baseURL
        self.headers = headers
        self.urlSession = urlSession
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        // `path` is an absolute URL only when it came from a response — an
        // operation name or a file `uri`. Those live on the API host, so the
        // key travels with them; anywhere else and the response would be
        // choosing where to send the key.
        let absolute = path.hasPrefix("http") ? URL(string: path) : nil
        let base = absolute ?? baseURL.appendingPathComponent(path)
        let trusted = absolute.map { ResponseURL.carriesCredentials($0, matching: baseURL) } ?? true

        var url = base
        if !query.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? base
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !apiKey.isEmpty, trusted {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        if trusted {
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        }
        return request
    }

    func send(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        query: [String: String] = [:]
    ) async throws -> JSONValue {
        try Self.checkAbsolute(path, baseURL: baseURL)
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
        try Self.checkAbsolute(path, baseURL: baseURL)
        let (data, response) = try await urlSession.data(for: request("GET", path))
        try Self.check(response, data)
        return data
    }

    /// An absolute path here always came from a response body — an operation
    /// name, a file `uri`. Failing loudly beats sending the request without the
    /// key and reporting whatever 401 comes back.
    static func checkAbsolute(_ path: String, baseURL: URL) throws {
        guard path.hasPrefix("http"), let url = URL(string: path) else { return }
        guard ResponseURL.carriesCredentials(url, matching: baseURL) else {
            throw AIError.invalidRequest(
                "Google returned a URL on \(url.host ?? "an unknown host"), which is not part of "
                + "\(baseURL.host ?? "the configured endpoint"). Refusing to send the API key there."
            )
        }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

public struct GoogleFile: Sendable, Hashable {
    public var name: String
    public var uri: String
    public var mimeType: String?
    public var displayName: String?
    public var sizeBytes: Int?
    public var state: String?
    public var raw: JSONValue

    init?(_ json: JSONValue) {
        let file = json["file"] ?? json
        guard let name = file["name"]?.stringValue else { return nil }
        self.name = name
        self.uri = file["uri"]?.stringValue ?? ""
        self.mimeType = file["mimeType"]?.stringValue
        self.displayName = file["displayName"]?.stringValue
        self.sizeBytes = file["sizeBytes"]?.intValue ?? Int(file["sizeBytes"]?.stringValue ?? "")
        self.state = file["state"]?.stringValue
        self.raw = file
    }

    public var isReady: Bool { state == nil || state == "ACTIVE" }
}

public struct GoogleFilesClient: Sendable {
    let http: GoogleHTTP
    let uploadBaseURL: URL

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        uploadBaseURL: URL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
        self.uploadBaseURL = uploadBaseURL
    }

    public func upload(
        _ data: Data,
        mimeType: String,
        displayName: String? = nil
    ) async throws -> GoogleFile {
        var start = URLRequest(url: uploadBaseURL.appendingPathComponent("files"))
        start.httpMethod = "POST"
        if !http.apiKey.isEmpty {
            start.setValue(http.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        for (field, value) in http.headers { start.setValue(value, forHTTPHeaderField: field) }
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "content-type")
        var metadata: [String: JSONValue] = [:]
        if let displayName { metadata["display_name"] = .string(displayName) }
        start.httpBody = try JSONEncoder().encode(JSONValue.object(["file": .object(metadata)]))

        let (startData, startResponse) = try await http.urlSession.data(for: start)
        try GoogleHTTP.check(startResponse, startData)
        guard let httpResponse = startResponse as? HTTPURLResponse,
              let uploadURLString = httpResponse.value(forHTTPHeaderField: "x-goog-upload-url")
                ?? httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString)
        else {
            throw AIError.transport("Google file upload did not return an upload URL")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = data

        let (uploadData, uploadResponse) = try await http.urlSession.data(for: upload)
        try GoogleHTTP.check(uploadResponse, uploadData)
        let json = try JSONDecoder().decode(JSONValue.self, from: uploadData)
        guard let file = GoogleFile(json) else {
            throw AIError.decoding("Google file upload returned no file name")
        }
        return file
    }

    public func get(_ name: String) async throws -> GoogleFile {
        let json = try await http.send("GET", Self.resourcePath(name))
        guard let file = GoogleFile(json) else {
            throw AIError.decoding("Google file \(name) returned no name")
        }
        return file
    }

    public func list(pageSize: Int? = nil, pageToken: String? = nil) async throws -> [GoogleFile] {
        var query: [String: String] = [:]
        if let pageSize { query["pageSize"] = String(pageSize) }
        if let pageToken { query["pageToken"] = pageToken }
        let json = try await http.send("GET", "files", query: query)
        return (json["files"]?.arrayValue ?? []).compactMap(GoogleFile.init)
    }

    @discardableResult
    public func delete(_ name: String) async throws -> Bool {
        _ = try await http.send("DELETE", Self.resourcePath(name))
        return true
    }

    public func waitUntilActive(
        _ name: String,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(120)
    ) async throws -> GoogleFile {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let file = try await get(name)
            if file.state == "FAILED" {
                throw AIError.transport("Google file \(name) failed processing")
            }
            if file.isReady { return file }
            guard ContinuousClock.now < deadline else {
                throw AIError.transport("Google file \(name) was still processing after \(timeout)")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    static func resourcePath(_ name: String) -> String {
        name.hasPrefix("files/") ? name : "files/\(name)"
    }
}

public struct GoogleCachedContentClient: Sendable {
    let http: GoogleHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        model: String,
        messages: [Message],
        systemInstruction: String? = nil,
        tools: [any AIToolProtocol] = [],
        ttlSeconds: Int? = nil,
        displayName: String? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = [
            "model": .string(model.hasPrefix("models/") ? model : "models/\(model)"),
            "contents": .array(GoogleModel.mapContents(messages))
        ]
        if let systemInstruction {
            body["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(systemInstruction)])])
            ])
        }
        if !tools.isEmpty {
            let probe = GoogleModel.requestBody(
                for: LanguageModelRequest(messages: messages, tools: tools), modelID: model
            )
            if let mapped = probe["tools"] { body["tools"] = mapped }
        }
        if let ttlSeconds { body["ttl"] = .string("\(ttlSeconds)s") }
        if let displayName { body["displayName"] = .string(displayName) }

        let json = try await http.send("POST", "cachedContents", json: .object(body))
        guard let name = json["name"]?.stringValue else {
            throw AIError.decoding("Google cachedContents create returned no name")
        }
        return name
    }

    public func list(pageSize: Int? = nil, pageToken: String? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let pageSize { query["pageSize"] = String(pageSize) }
        if let pageToken { query["pageToken"] = pageToken }
        return try await http.send("GET", "cachedContents", query: query)
    }

    public func get(_ name: String) async throws -> JSONValue {
        try await http.send("GET", name)
    }

    @discardableResult
    public func updateTTL(_ name: String, ttlSeconds: Int) async throws -> JSONValue {
        try await http.send(
            "PATCH", name,
            json: .object(["ttl": .string("\(ttlSeconds)s")]),
            query: ["updateMask": "ttl"]
        )
    }

    @discardableResult
    public func delete(_ name: String) async throws -> Bool {
        _ = try await http.send("DELETE", name)
        return true
    }
}

public struct GoogleBatchClient: Sendable {
    let http: GoogleHTTP

    public struct Request: Sendable {
        public var key: String
        public var messages: [Message]
        public var systemInstruction: String?

        public init(key: String, messages: [Message], systemInstruction: String? = nil) {
            self.key = key
            self.messages = messages
            self.systemInstruction = systemInstruction
        }

        var wire: JSONValue {
            var request: [String: JSONValue] = [
                "contents": .array(GoogleModel.mapContents(messages))
            ]
            if let systemInstruction {
                request["systemInstruction"] = .object([
                    "parts": .array([.object(["text": .string(systemInstruction)])])
                ])
            }
            return .object([
                "request": .object(request),
                "metadata": .object(["key": .string(key)])
            ])
        }
    }

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        model: String,
        displayName: String,
        requests: [Request]
    ) async throws -> String {
        let body: JSONValue = .object([
            "batch": .object([
                "display_name": .string(displayName),
                "input_config": .object([
                    "requests": .object(["requests": .array(requests.map(\.wire))])
                ])
            ])
        ])
        let json = try await http.send(
            "POST", "models/\(model):batchGenerateContent", json: body
        )
        guard let name = json["name"]?.stringValue else {
            throw AIError.decoding("Google batchGenerateContent returned no operation name")
        }
        return name
    }

    public func createEmbeddings(
        model: String,
        displayName: String,
        texts: [String]
    ) async throws -> String {
        let requests = texts.enumerated().map { index, text -> JSONValue in
            .object([
                "request": .object([
                    "model": .string("models/\(model)"),
                    "content": .object(["parts": .array([.object(["text": .string(text)])])])
                ]),
                "metadata": .object(["key": .string("request-\(index)")])
            ])
        }
        let body: JSONValue = .object([
            "batch": .object([
                "display_name": .string(displayName),
                "input_config": .object([
                    "requests": .object(["requests": .array(requests)])
                ])
            ])
        ])
        let json = try await http.send(
            "POST", "models/\(model):asyncBatchEmbedContent", json: body
        )
        guard let name = json["name"]?.stringValue else {
            throw AIError.decoding("Google asyncBatchEmbedContent returned no operation name")
        }
        return name
    }

    public func get(_ name: String) async throws -> JSONValue {
        try await http.send("GET", name)
    }

    public func list(pageSize: Int? = nil, pageToken: String? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        if let pageSize { query["pageSize"] = String(pageSize) }
        if let pageToken { query["pageToken"] = pageToken }
        return try await http.send("GET", "batches", query: query)
    }

    @discardableResult
    public func cancel(_ name: String) async throws -> JSONValue {
        try await http.send("POST", "\(name):cancel", json: .object([:]))
    }

    @discardableResult
    public func delete(_ name: String) async throws -> Bool {
        _ = try await http.send("DELETE", name)
        return true
    }
}

public extension GoogleModel {
    func countTokens(_ messages: [Message], systemInstruction: String? = nil) async throws -> Int {
        var body: [String: JSONValue] = ["contents": .array(Self.mapContents(messages))]
        if let systemInstruction {
            body["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(systemInstruction)])])
            ])
        }
        let http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
        let json = try await http.send(
            "POST", "models/\(modelID):countTokens", json: .object(body)
        )
        return json["totalTokens"]?.intValue ?? 0
    }
}

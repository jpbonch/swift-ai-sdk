import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct XaiHTTP: Sendable {
    var apiKey: String
    var baseURL: URL
    var headers: [String: String]
    var urlSession: URLSession

    init(apiKey: String?, baseURL: URL, headers: [String: String], urlSession: URLSession) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ""
        self.baseURL = baseURL
        self.headers = headers
        self.urlSession = urlSession
    }

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    }

    func url(_ path: String, query: [String: String]) -> URL {
        let base = baseURL.appendingPathComponent(path)
        guard !query.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url ?? base
    }

    func send(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        query: [String: String] = [:]
    ) async throws -> JSONValue {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        authorize(&request)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data)
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func download(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        authorize(&request)
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data)
        return data
    }

    func multipart(_ path: String, form: MultipartForm) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue(
            "multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "content-type"
        )
        request.httpBody = form.finish()
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data)
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

public struct XaiFile: Sendable {
    public var id: String
    public var filename: String?
    public var bytes: Int?
    public var createdAt: Int?
    public var expiresAt: Int?
    public var publicURL: String?
    public var raw: JSONValue

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        self.filename = json["filename"]?.stringValue
        self.bytes = json["bytes"]?.intValue
        self.createdAt = json["created_at"]?.intValue
        self.expiresAt = json["expires_at"]?.intValue
        self.publicURL = json["public_url"]?.stringValue
        self.raw = json
    }
}

public struct XaiFilesClient: Sendable {
    let http: XaiHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = XaiHTTP(apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession)
    }

    public func upload(
        _ data: Data,
        filename: String,
        mediaType: String = "application/octet-stream",
        expiresAfter: Int? = nil
    ) async throws -> XaiFile {
        var form = MultipartForm(boundary: "swift-ai-sdk-xai-files")
        if let expiresAfter { form.addField(name: "expires_after", value: String(expiresAfter)) }
        form.addFile(name: "file", filename: filename, mediaType: mediaType, data: data)
        let json = try await http.multipart("files", form: form)
        guard let file = XaiFile(json) else {
            throw AIError.decoding("xAI file upload returned no id")
        }
        return file
    }

    public func list(
        limit: Int? = nil,
        order: String? = nil,
        sortBy: String? = nil,
        paginationToken: String? = nil,
        after: String? = nil,
        filter: String? = nil
    ) async throws -> [XaiFile] {
        let json = try await http.send("GET", "files", query: XaiCollectionsClient.query([
            "limit": limit.map(String.init),
            "order": order,
            "sort_by": sortBy,
            "pagination_token": paginationToken,
            "after": after,
            "filter": filter
        ]))
        let items = json["files"]?.arrayValue ?? json["data"]?.arrayValue ?? []
        return items.compactMap(XaiFile.init)
    }

    @discardableResult
    public func update(_ fileID: String, body: JSONValue) async throws -> JSONValue {
        try await http.send("PUT", "files/\(fileID)", json: body)
    }

    public func get(_ fileID: String) async throws -> XaiFile {
        let json = try await http.send("GET", "files/\(fileID)")
        guard let file = XaiFile(json) else {
            throw AIError.decoding("xAI file \(fileID) returned no id")
        }
        return file
    }

    public func download(_ fileID: String) async throws -> Data {
        try await http.download("files/\(fileID)/content")
    }

    @discardableResult
    public func delete(_ fileID: String) async throws -> Bool {
        let json = try await http.send("DELETE", "files/\(fileID)")
        return json["deleted"]?.boolValue ?? true
    }
}

public struct XaiBatchClient: Sendable {
    let http: XaiHTTP

    public struct Request: Sendable {
        public var id: String
        public var endpoint: String
        public var model: String
        public var body: JSONValue

        public init(id: String, endpoint: String = "/v1/chat/completions", model: String, body: JSONValue) {
            self.id = id
            self.endpoint = endpoint
            self.model = model
            self.body = body
        }

        var wire: JSONValue {
            .object([
                "batch_request_id": .string(id),
                "endpoint": .string(endpoint),
                "model": .string(model),
                "chat_get_completion": body
            ])
        }
    }

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = XaiHTTP(apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession)
    }

    public func create(name: String, requests: [Request]) async throws -> String {
        let body: JSONValue = .object([
            "name": .string(name),
            "batch_requests": .array(requests.map(\.wire))
        ])
        let json = try await http.send("POST", "batches", json: body)
        guard let batchID = json["batch_id"]?.stringValue else {
            throw AIError.decoding("xAI batch create returned no batch_id")
        }
        return batchID
    }

    public func list() async throws -> JSONValue {
        try await http.send("GET", "batches")
    }

    public func get(_ batchID: String) async throws -> JSONValue {
        try await http.send("GET", "batches/\(batchID)")
    }

    public func requests(_ batchID: String) async throws -> JSONValue {
        try await http.send("GET", "batches/\(batchID)/requests")
    }

    public func results(_ batchID: String) async throws -> JSONValue {
        try await http.send("GET", "batches/\(batchID)/results")
    }

    @discardableResult
    public func addRequests(_ batchID: String, requests: [Request]) async throws -> JSONValue {
        try await http.send(
            "POST", "batches/\(batchID)/requests",
            json: .object(["batch_requests": .array(requests.map(\.wire))])
        )
    }

    @discardableResult
    public func cancel(_ batchID: String) async throws -> JSONValue {
        try await http.send("POST", "batches/\(batchID):cancel", json: .object([:]))
    }
}

public struct XaiModelsClient: Sendable {
    let http: XaiHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = XaiHTTP(apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession)
    }

    public func list() async throws -> JSONValue {
        try await http.send("GET", "models")
    }

    public func get(_ modelID: String) async throws -> JSONValue {
        try await http.send("GET", "models/\(modelID)")
    }

    public func languageModels() async throws -> JSONValue {
        try await http.send("GET", "language-models")
    }

    public func languageModel(_ modelID: String) async throws -> JSONValue {
        try await http.send("GET", "language-models/\(modelID)")
    }

    public func imageGenerationModels() async throws -> JSONValue {
        try await http.send("GET", "image-generation-models")
    }

    public func imageGenerationModel(_ modelID: String) async throws -> JSONValue {
        try await http.send("GET", "image-generation-models/\(modelID)")
    }

    public func videoGenerationModels() async throws -> JSONValue {
        try await http.send("GET", "video-generation-models")
    }

    public func videoGenerationModel(_ modelID: String) async throws -> JSONValue {
        try await http.send("GET", "video-generation-models/\(modelID)")
    }
}

public struct XaiPlatformClient: Sendable {
    let http: XaiHTTP
    let voiceHTTP: XaiHTTP

    public init(
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        voiceBaseURL: URL = URL(string: "https://api.x.ai/v2")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.http = XaiHTTP(apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession)
        self.voiceHTTP = XaiHTTP(
            apiKey: apiKey, baseURL: voiceBaseURL, headers: headers, urlSession: urlSession
        )
    }

    public func apiKeyInfo() async throws -> JSONValue {
        try await http.send("GET", "api-key")
    }

    public func tokenizeText(_ text: String, model: String) async throws -> [Int] {
        let json = try await tokenizeText(
            body: .object(["text": .string(text), "model": .string(model)])
        )
        return json["token_ids"]?.arrayValue?.compactMap(\.intValue) ?? []
    }

    public func tokenizeText(body: JSONValue) async throws -> JSONValue {
        try await http.send("POST", "tokenize-text", json: body)
    }

    public func createPhoneNumber(
        origin: String,
        name: String,
        options: JSONValue? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = ["origin": .string(origin), "name": .string(name)]
        if case .object(let extra)? = options {
            for (key, value) in extra { body[key] = value }
        }
        return try await voiceHTTP.send("POST", "phone-numbers", json: .object(body))
    }

    @discardableResult
    public func referCall(_ callID: String, body: JSONValue) async throws -> JSONValue {
        try await http.send("POST", "realtime/calls/\(callID)/refer", json: body)
    }

    @discardableResult
    public func hangUpCall(_ callID: String) async throws -> JSONValue {
        try await http.send("POST", "realtime/calls/\(callID)/hangup", json: .object([:]))
    }

    public func voices() async throws -> JSONValue {
        try await http.send("GET", "tts/voices")
    }

    public func voice(_ voiceID: String) async throws -> JSONValue {
        try await http.send("GET", "tts/voices/\(voiceID)")
    }

    public func customVoices() async throws -> JSONValue {
        try await http.send("GET", "custom-voices")
    }

    @discardableResult
    public func createCustomVoice(body: JSONValue) async throws -> JSONValue {
        try await http.send("POST", "custom-voices", json: body)
    }
}

public struct XaiCollectionsClient: Sendable {
    let management: XaiHTTP
    let inference: XaiHTTP

    public init(
        managementAPIKey: String? = nil,
        apiKey: String? = nil,
        managementBaseURL: URL = URL(string: "https://management-api.x.ai/v1")!,
        baseURL: URL = URL(string: "https://api.x.ai/v1")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        let resolvedManagementKey = managementAPIKey
            ?? ProcessInfo.processInfo.environment["XAI_MANAGEMENT_API_KEY"]
            ?? apiKey
        self.management = XaiHTTP(
            apiKey: resolvedManagementKey, baseURL: managementBaseURL,
            headers: headers, urlSession: urlSession
        )
        self.inference = XaiHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func create(
        name: String,
        description: String? = nil,
        indexConfiguration: JSONValue? = nil,
        fieldDefinitions: JSONValue? = nil,
        teamID: String? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = ["collection_name": .string(name)]
        if let description { body["collection_description"] = .string(description) }
        if let indexConfiguration { body["index_configuration"] = indexConfiguration }
        if let fieldDefinitions { body["field_definitions"] = fieldDefinitions }
        if let teamID { body["team_id"] = .string(teamID) }
        let json = try await management.send("POST", "collections", json: .object(body))
        guard let id = json["collection_id"]?.stringValue ?? json["id"]?.stringValue else {
            throw AIError.decoding("xAI collection create returned no collection_id")
        }
        return id
    }

    public func list(
        teamID: String? = nil,
        limit: Int? = nil,
        order: String? = nil,
        sortBy: String? = nil,
        paginationToken: String? = nil,
        filter: String? = nil
    ) async throws -> JSONValue {
        try await management.send("GET", "collections", query: Self.query([
            "team_id": teamID,
            "limit": limit.map(String.init),
            "order": order,
            "sort_by": sortBy,
            "pagination_token": paginationToken,
            "filter": filter
        ]))
    }

    public func get(_ collectionID: String, teamID: String? = nil) async throws -> JSONValue {
        try await management.send(
            "GET", "collections/\(collectionID)", query: Self.query(["team_id": teamID])
        )
    }

    @discardableResult
    public func delete(_ collectionID: String, teamID: String? = nil) async throws -> Bool {
        let json = try await management.send(
            "DELETE", "collections/\(collectionID)", query: Self.query(["team_id": teamID])
        )
        return json["deleted"]?.boolValue ?? true
    }

    @discardableResult
    public func update(
        _ collectionID: String,
        name: String? = nil,
        description: String? = nil,
        indexConfiguration: JSONValue? = nil,
        fieldDefinitions: JSONValue? = nil,
        teamID: String? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let name { body["collection_name"] = .string(name) }
        if let description { body["collection_description"] = .string(description) }
        if let indexConfiguration { body["index_configuration"] = indexConfiguration }
        if let fieldDefinitions { body["field_definitions"] = fieldDefinitions }
        if let teamID { body["team_id"] = .string(teamID) }
        return try await management.send(
            "PUT", "collections/\(collectionID)", json: .object(body)
        )
    }

    @discardableResult
    public func addDocument(
        collectionID: String,
        fileID: String,
        fields: JSONValue? = nil,
        teamID: String? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let fields { body["fields"] = fields }
        if let teamID { body["team_id"] = .string(teamID) }
        return try await management.send(
            "POST", "collections/\(collectionID)/documents/\(fileID)",
            json: body.isEmpty ? .object([:]) : .object(body)
        )
    }

    public func listDocuments(
        collectionID: String,
        teamID: String? = nil,
        limit: Int? = nil,
        order: String? = nil,
        sortBy: String? = nil,
        paginationToken: String? = nil,
        filter: String? = nil
    ) async throws -> JSONValue {
        try await management.send(
            "GET", "collections/\(collectionID)/documents",
            query: Self.query([
                "team_id": teamID,
                "limit": limit.map(String.init),
                "order": order,
                "sort_by": sortBy,
                "pagination_token": paginationToken,
                "filter": filter
            ])
        )
    }

    public func document(
        collectionID: String, fileID: String, teamID: String? = nil
    ) async throws -> JSONValue {
        try await management.send(
            "GET", "collections/\(collectionID)/documents/\(fileID)",
            query: Self.query(["team_id": teamID])
        )
    }

    public func documents(
        collectionID: String, fileIDs: [String], teamID: String? = nil
    ) async throws -> JSONValue {
        var query = Self.query(["team_id": teamID])
        query["file_ids"] = fileIDs.joined(separator: ",")
        return try await management.send(
            "GET", "collections/\(collectionID)/documents:batchGet", query: query
        )
    }

    @discardableResult
    public func regenerateIndices(
        collectionID: String, fileID: String, teamID: String? = nil
    ) async throws -> JSONValue {
        try await management.send(
            "PATCH", "collections/\(collectionID)/documents/\(fileID)",
            json: .object([:]), query: Self.query(["team_id": teamID])
        )
    }

    @discardableResult
    public func removeDocument(
        collectionID: String, fileID: String, teamID: String? = nil
    ) async throws -> Bool {
        let json = try await management.send(
            "DELETE", "collections/\(collectionID)/documents/\(fileID)",
            query: Self.query(["team_id": teamID])
        )
        return json["deleted"]?.boolValue ?? true
    }

    public func search(
        query: String,
        source: JSONValue,
        filter: String? = nil,
        minK: JSONValue? = nil,
        maxK: JSONValue? = nil,
        instructions: String? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [
            "query": .string(query),
            "source": source
        ]
        if let filter { body["filter"] = .string(filter) }
        if let minK { body["min_k"] = minK }
        if let maxK { body["max_k"] = maxK }
        if let instructions { body["instructions"] = .string(instructions) }
        return try await inference.send("POST", "documents/search", json: .object(body))
    }

    static func query(_ pairs: [String: String?]) -> [String: String] {
        pairs.compactMapValues { $0 }
    }
}

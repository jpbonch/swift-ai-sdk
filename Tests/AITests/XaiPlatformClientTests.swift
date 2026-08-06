import XCTest
@testable import AI

final class RecordedRequest: @unchecked Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let body: JSONValue?

    init(_ request: URLRequest, body: Data?) {
        self.method = request.httpMethod ?? ""
        self.url = request.url ?? URL(string: "about:blank")!
        self.authorization = request.value(forHTTPHeaderField: "Authorization")
        self.body = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        self.rawBody = body
    }

    let rawBody: Data?

    var path: String { url.path }
    var host: String { url.host ?? "" }

    func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    /// Decodes an `application/x-www-form-urlencoded` body into a dictionary.
    var formBody: [String: String]? {
        guard let rawBody, let text = String(data: rawBody, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] =
                parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }
}

final class StubTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let lock = NSLock()
    nonisolated(unsafe) static var recorded: [RecordedRequest] = []
    nonisolated(unsafe) static var response: JSONValue = .object([:])
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]
    nonisolated(unsafe) static var router: (@Sendable (RecordedRequest) -> JSONValue?)?

    static func reset(response: JSONValue = .object([:])) {
        lock.lock()
        recorded = []
        self.response = response
        status = 200
        responseHeaders = [:]
        router = nil
        lock.unlock()
    }

    /// Serve different payloads per URL. Returning nil from the route 404s that request, which
    /// is what discovery probing expects for endpoints a server doesn't publish.
    static func route(_ router: @escaping @Sendable (RecordedRequest) -> JSONValue?) {
        lock.lock()
        self.router = router
        lock.unlock()
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody
            ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let size = 4096
                var buffer = [UInt8](repeating: 0, count: size)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                return data
            }

        let recordedRequest = RecordedRequest(request, body: bodyData)

        Self.lock.lock()
        Self.recorded.append(recordedRequest)
        let router = Self.router
        let fallback = Self.response
        var statusCode = Self.status
        var headers = Self.responseHeaders
        Self.lock.unlock()

        var payload = fallback
        if let router {
            if let routed = router(recordedRequest) {
                payload = routed
                statusCode = 200
                headers = [:]
            } else if statusCode == 200 {
                statusCode = 404
                payload = .object(["error": .string("no route")])
            }
        }

        headers["content-type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class XaiCollectionsClientTests: XCTestCase {

    private func client() -> XaiCollectionsClient {
        XaiCollectionsClient(
            managementAPIKey: "mgmt-key",
            apiKey: "inference-key",
            urlSession: StubTransport.session()
        )
    }

    func testManagementCallsHitTheManagementHostWithTheManagementKey() async throws {
        StubTransport.reset(response: .object(["collection_id": "col_1"]))
        _ = try await client().create(name: "Reports", description: "Q3")

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.host, "management-api.x.ai")
        XCTAssertEqual(request.path, "/v1/collections")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.authorization, "Bearer mgmt-key")
        XCTAssertEqual(request.body?["collection_name"], "Reports")
        XCTAssertEqual(request.body?["collection_description"], "Q3")
    }

    func testSearchStaysOnTheInferenceHostWithTheInferenceKey() async throws {
        StubTransport.reset()
        _ = try await client().search(query: "revenue", source: ["collection_ids": .array(["col_1"])])

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.host, "api.x.ai")
        XCTAssertEqual(request.path, "/v1/documents/search")
        XCTAssertEqual(request.authorization, "Bearer inference-key")
    }

    func testAddDocumentPutsTheFileIDInThePath() async throws {
        StubTransport.reset()
        _ = try await client().addDocument(
            collectionID: "col_1", fileID: "file_9", fields: ["isbn": "978"]
        )

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/collections/col_1/documents/file_9")
        XCTAssertEqual(request.body?["fields"]?["isbn"], "978")
        XCTAssertNil(request.body?["file_id"], "the file id belongs in the path, not the body")
    }

    func testDocumentEndpointsUseTheDocumentedVerbs() async throws {
        StubTransport.reset()
        let collections = client()

        _ = try await collections.update("col_1", name: "Renamed")
        _ = try await collections.listDocuments(collectionID: "col_1", limit: 25, filter: "status:X")
        _ = try await collections.document(collectionID: "col_1", fileID: "file_9")
        _ = try await collections.documents(collectionID: "col_1", fileIDs: ["a", "b"])
        _ = try await collections.regenerateIndices(collectionID: "col_1", fileID: "file_9")
        _ = try await collections.removeDocument(collectionID: "col_1", fileID: "file_9")

        let requests = StubTransport.requests
        XCTAssertEqual(requests[0].method, "PUT")
        XCTAssertEqual(requests[0].path, "/v1/collections/col_1")

        XCTAssertEqual(requests[1].method, "GET")
        XCTAssertEqual(requests[1].path, "/v1/collections/col_1/documents")
        XCTAssertEqual(requests[1].queryValue("limit"), "25")
        XCTAssertEqual(requests[1].queryValue("filter"), "status:X")

        XCTAssertEqual(requests[2].path, "/v1/collections/col_1/documents/file_9")
        XCTAssertEqual(requests[2].method, "GET")

        XCTAssertEqual(requests[3].path, "/v1/collections/col_1/documents:batchGet")
        XCTAssertEqual(requests[3].queryValue("file_ids"), "a,b")

        XCTAssertEqual(requests[4].method, "PATCH")
        XCTAssertEqual(requests[4].path, "/v1/collections/col_1/documents/file_9")

        XCTAssertEqual(requests[5].method, "DELETE")
        XCTAssertEqual(requests[5].path, "/v1/collections/col_1/documents/file_9")
    }

    func testTeamIDRidesAsAQueryParameter() async throws {
        StubTransport.reset()
        _ = try await client().list(teamID: "team_7", limit: 10, order: "asc")

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.queryValue("team_id"), "team_7")
        XCTAssertEqual(request.queryValue("limit"), "10")
        XCTAssertEqual(request.queryValue("order"), "asc")
    }

    func testManagementKeyFallsBackToTheInferenceKey() async throws {
        StubTransport.reset(response: .object(["collection_id": "col_1"]))
        let fallback = XaiCollectionsClient(
            apiKey: "only-key", urlSession: StubTransport.session()
        )
        _ = try await fallback.create(name: "Reports")
        XCTAssertEqual(StubTransport.requests.first?.authorization, "Bearer only-key")
    }
}

final class XaiModelsClientTests: XCTestCase {

    func testEveryModelCatalogEndpoint() async throws {
        StubTransport.reset(response: .object(["models": .array([])]))
        let models = XaiModelsClient(apiKey: "k", urlSession: StubTransport.session())

        _ = try await models.list()
        _ = try await models.get("grok-4.5")
        _ = try await models.languageModels()
        _ = try await models.languageModel("grok-4.5")
        _ = try await models.imageGenerationModels()
        _ = try await models.imageGenerationModel("grok-2-image")
        _ = try await models.videoGenerationModels()
        _ = try await models.videoGenerationModel("grok-video")

        XCTAssertEqual(StubTransport.requests.map(\.path), [
            "/v1/models",
            "/v1/models/grok-4.5",
            "/v1/language-models",
            "/v1/language-models/grok-4.5",
            "/v1/image-generation-models",
            "/v1/image-generation-models/grok-2-image",
            "/v1/video-generation-models",
            "/v1/video-generation-models/grok-video"
        ])
        XCTAssertTrue(StubTransport.requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(StubTransport.requests.allSatisfy { $0.host == "api.x.ai" })
    }
}

final class XaiPlatformExtrasTests: XCTestCase {

    func testTokenizeTextAndAPIKeyInfo() async throws {
        StubTransport.reset(response: .object([
            "token_ids": .array([.number(1), .number(2), .number(3)])
        ]))
        let platform = XaiPlatformClient(apiKey: "k", urlSession: StubTransport.session())

        let tokens = try await platform.tokenizeText("hello", model: "grok-4.5")
        XCTAssertEqual(tokens, [1, 2, 3])

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/tokenize-text")
        XCTAssertEqual(request.body?["text"], "hello")
        XCTAssertEqual(request.body?["model"], "grok-4.5")

        StubTransport.reset(response: .object(["api_key_id": "key_1"]))
        _ = try await platform.apiKeyInfo()
        XCTAssertEqual(StubTransport.requests.first?.path, "/v1/api-key")
        XCTAssertEqual(StubTransport.requests.first?.method, "GET")
    }

    func testPhoneNumbersUseTheV2Endpoint() async throws {
        StubTransport.reset(response: .object(["phone_number": "+15550100"]))
        let platform = XaiPlatformClient(apiKey: "k", urlSession: StubTransport.session())
        _ = try await platform.createPhoneNumber(origin: "xai_provisioned", name: "support")

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v2/phone-numbers")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body?["origin"], "xai_provisioned")
        XCTAssertEqual(request.body?["name"], "support")
    }

    func testCallControlAndVoiceCatalog() async throws {
        StubTransport.reset()
        let platform = XaiPlatformClient(apiKey: "k", urlSession: StubTransport.session())

        _ = try await platform.referCall("call_1", body: ["target": "sip:agent@example.com"])
        _ = try await platform.hangUpCall("call_1")
        _ = try await platform.voices()
        _ = try await platform.voice("ara")
        _ = try await platform.customVoices()

        XCTAssertEqual(StubTransport.requests.map(\.path), [
            "/v1/realtime/calls/call_1/refer",
            "/v1/realtime/calls/call_1/hangup",
            "/v1/tts/voices",
            "/v1/tts/voices/ara",
            "/v1/custom-voices"
        ])
    }
}

final class XaiBatchAndFileTests: XCTestCase {

    func testBatchRequestAppendAndCancel() async throws {
        StubTransport.reset()
        let batches = XaiBatchClient(apiKey: "k", urlSession: StubTransport.session())
        let request = XaiBatchClient.Request(
            id: "r1", model: "grok-4.5", body: ["messages": .array([])]
        )

        _ = try await batches.addRequests("batch_1", requests: [request])
        _ = try await batches.cancel("batch_1")

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].path, "/v1/batches/batch_1/requests")
        XCTAssertEqual(
            recorded[0].body?["batch_requests"]?.arrayValue?.first?["batch_request_id"], "r1"
        )
        XCTAssertEqual(recorded[1].method, "POST")
        XCTAssertEqual(recorded[1].path, "/v1/batches/batch_1:cancel")
    }

    func testFileListQueryParametersAndUpdate() async throws {
        StubTransport.reset(response: .object(["data": .array([])]))
        let files = XaiFilesClient(apiKey: "k", urlSession: StubTransport.session())

        _ = try await files.list(limit: 50, order: "asc", after: "file_3", filter: "name:report")
        _ = try await files.update("file_3", body: ["filename": "renamed.pdf"])

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].queryValue("limit"), "50")
        XCTAssertEqual(recorded[0].queryValue("order"), "asc")
        XCTAssertEqual(recorded[0].queryValue("after"), "file_3")
        XCTAssertEqual(recorded[0].queryValue("filter"), "name:report")

        XCTAssertEqual(recorded[1].method, "PUT")
        XCTAssertEqual(recorded[1].path, "/v1/files/file_3")
        XCTAssertEqual(recorded[1].body?["filename"], "renamed.pdf")
    }

    func testUploadPutsExpiresAfterBeforeTheFileField() async throws {
        StubTransport.reset(response: .object(["id": "file_1"]))
        let files = XaiFilesClient(apiKey: "k", urlSession: StubTransport.session())
        _ = try await files.upload(
            Data("hello".utf8), filename: "note.txt",
            mediaType: "text/plain", expiresAfter: 86_400
        )

        let request = try XCTUnwrap(StubTransport.requests.first)
        XCTAssertEqual(request.path, "/v1/files")
        XCTAssertEqual(request.method, "POST")
    }
}

final class XaiResponseLifecycleTests: XCTestCase {

    func testRetrieveAndDeleteStoredResponses() async throws {
        StubTransport.reset(response: .object(["id": "resp_1"]))
        let model = XaiModel("grok-4.5", apiKey: "k", urlSession: StubTransport.session())

        _ = try await model.retrieveResponse("resp_1")
        _ = try await model.deleteResponse("resp_1")

        let recorded = StubTransport.requests
        XCTAssertEqual(recorded[0].method, "GET")
        XCTAssertEqual(recorded[0].path, "/v1/responses/resp_1")
        XCTAssertEqual(recorded[0].authorization, "Bearer k")
        XCTAssertEqual(recorded[1].method, "DELETE")
        XCTAssertEqual(recorded[1].path, "/v1/responses/resp_1")
    }
}

import XCTest
@testable import AI

final class MCPNotionLiveTests: XCTestCase {

    private let httpURL = URL(string: "https://mcp.notion.com/mcp")!
    private let sseURL = URL(string: "https://mcp.notion.com/sse")!

    private actor Provider: MCPOAuthClientProvider {
        nonisolated let redirectURL = URL(string: "http://127.0.0.1:8765/callback")!
        nonisolated let clientMetadata: MCPOAuthClientMetadata

        private var storedTokens: MCPOAuthTokens?
        private var storedClientInfo: MCPOAuthClientInformation?
        private var storedVerifier: String?
        private var storedState: String?
        private(set) var opened: [URL] = []

        init(tokens: MCPOAuthTokens? = nil) {
            self.clientMetadata = MCPOAuthClientMetadata(
                redirectURIs: [URL(string: "http://127.0.0.1:8765/callback")!],
                clientName: "swift-ai-sdk live test"
            )
            self.storedTokens = tokens
        }

        func tokens() async -> MCPOAuthTokens? { storedTokens }
        func saveTokens(_ tokens: MCPOAuthTokens) async { storedTokens = tokens }
        func clientInformation() async -> MCPOAuthClientInformation? { storedClientInfo }
        func saveClientInformation(_ info: MCPOAuthClientInformation) async { storedClientInfo = info }
        func saveCodeVerifier(_ verifier: String) async { storedVerifier = verifier }
        func codeVerifier() async -> String? { storedVerifier }
        func saveState(_ state: String) async { storedState = state }
        func state() async -> String? { storedState }
        func redirectToAuthorization(_ url: URL) async throws { opened.append(url) }
    }

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["MCP_LIVE_NOTION"] != nil else {
            throw XCTSkip("set MCP_LIVE_NOTION=1 to run the Notion MCP OAuth live tests")
        }
    }

    func testNotionChallengesUnauthenticatedRequests() async throws {
        try requireLive()
        var request = URLRequest(url: httpURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)

        let challenge = try XCTUnwrap(http.value(forHTTPHeaderField: "WWW-Authenticate"))
        let metadataURL = try XCTUnwrap(
            MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: challenge)
        )
        XCTAssertEqual(
            metadataURL.absoluteString,
            "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp"
        )
    }

    func testDiscoveryResolvesNotionAuthorizationServer() async throws {
        try requireLive()
        let discovered = try await MCPOAuthFlow.discover(for: httpURL)

        let resource = try XCTUnwrap(discovered.resource)
        XCTAssertEqual(resource.resource, httpURL)
        XCTAssertEqual(resource.authorizationServers.first?.absoluteString, "https://mcp.notion.com")

        let server = discovered.authorizationServer
        XCTAssertEqual(server.issuer, "https://mcp.notion.com")
        XCTAssertEqual(server.authorizationEndpoint.absoluteString, "https://mcp.notion.com/authorize")
        XCTAssertEqual(server.tokenEndpoint.absoluteString, "https://mcp.notion.com/token")
        XCTAssertEqual(server.registrationEndpoint?.absoluteString, "https://mcp.notion.com/register")
        XCTAssertTrue(server.codeChallengeMethodsSupported.contains("S256"))
    }

    func testDiscoveryForTheSSEEndpointUsesItsOwnResourceMetadata() async throws {
        try requireLive()
        let discovered = try await MCPOAuthFlow.discover(for: sseURL)
        XCTAssertEqual(discovered.resource?.resource, sseURL)
        XCTAssertEqual(discovered.authorizationServer.issuer, "https://mcp.notion.com")
    }

    func testUnauthorizedHTTPTransportProducesAnAuthorizationURL() async throws {
        try requireLive()
        let provider = Provider()
        let session = MCPOAuthSession(serverURL: httpURL, provider: provider)
        let transport = MCPHTTPTransport(url: httpURL, auth: session)
        let client = MCPClient(transport: transport)

        do {
            _ = try await client.tools()
            XCTFail("expected Notion to demand authorization")
        } catch let error as AIError {
            guard case .authorizationRequired(let url) = error else {
                return XCTFail("expected .authorizationRequired, got \(error)")
            }
            try await assertUsableAuthorizationURL(url, provider: provider, resource: httpURL)
        }
    }

    func testUnauthorizedSSETransportProducesAnAuthorizationURL() async throws {
        try requireLive()
        let provider = Provider()
        let session = MCPOAuthSession(serverURL: sseURL, provider: provider)
        let transport = MCPSSETransport(url: sseURL, auth: session, requestTimeout: 20)
        let client = MCPClient(transport: transport)

        do {
            _ = try await client.tools()
            XCTFail("expected Notion to demand authorization")
        } catch let error as AIError {
            guard case .authorizationRequired(let url) = error else {
                return XCTFail("expected .authorizationRequired, got \(error)")
            }
            try await assertUsableAuthorizationURL(url, provider: provider, resource: sseURL)
        }
        await transport.close()
    }

    func testAuthorizationURLIsAcceptedByNotion() async throws {
        try requireLive()
        let provider = Provider()
        let session = MCPOAuthSession(serverURL: httpURL, provider: provider)
        let url = try await session.authorizationURL()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertNotEqual(
            http.statusCode, 400,
            "Notion rejected the authorization request: \(body.prefix(400))"
        )
        XCTAssertTrue(
            (200..<400).contains(http.statusCode),
            "expected a sign-in page or redirect, got \(http.statusCode): \(body.prefix(400))"
        )
    }

    private func assertUsableAuthorizationURL(
        _ url: URL, provider: Provider, resource: URL
    ) async throws {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        XCTAssertEqual(components.host, "mcp.notion.com")
        XCTAssertEqual(components.path, "/authorize")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("redirect_uri"), provider.redirectURL.absoluteString)
        XCTAssertEqual(value("resource"), resource.absoluteString)

        let storedClientInfo = await provider.clientInformation()
        let storedVerifier = await provider.codeVerifier()
        let storedState = await provider.state()

        let clientID = try XCTUnwrap(value("client_id"))
        XCTAssertFalse(clientID.isEmpty)
        XCTAssertEqual(try XCTUnwrap(storedClientInfo).clientID, clientID)

        let challenge = try XCTUnwrap(value("code_challenge"))
        let verifier = try XCTUnwrap(storedVerifier)
        XCTAssertEqual(challenge, try MCPOAuthFlow.codeChallenge(for: verifier))

        XCTAssertEqual(try XCTUnwrap(value("state")), storedState)

        let opened = await provider.opened
        XCTAssertEqual(opened, [url])
    }
}

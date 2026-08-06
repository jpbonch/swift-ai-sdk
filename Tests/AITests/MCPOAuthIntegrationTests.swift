import XCTest
@testable import AI

final class MCPOAuthDiscoveryTests: XCTestCase {

    func testWellKnownURLsPreserveTheIssuerPath() {
        let tenant = URL(string: "https://mcp.example.com/tenant/acme/mcp")!
        let urls = MCPOAuthFlow.wellKnownURLs("oauth-authorization-server", issuer: tenant)
            .map(\.absoluteString)

        XCTAssertEqual(urls, [
            "https://mcp.example.com/.well-known/oauth-authorization-server/tenant/acme/mcp",
            "https://mcp.example.com/.well-known/oauth-authorization-server"
        ], "RFC 8414 puts the well-known segment between host and path, with an origin fallback")
    }

    func testWellKnownURLsForRootIssuerAreNotDuplicated() {
        let root = URL(string: "https://auth.example.com/")!
        XCTAssertEqual(
            MCPOAuthFlow.wellKnownURLs("oauth-protected-resource", issuer: root).map(\.absoluteString),
            ["https://auth.example.com/.well-known/oauth-protected-resource"]
        )
    }

    func testResourceMetadataURLParsesTheChallenge() {
        let quoted = #"Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#
        XCTAssertEqual(
            MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: quoted)?.absoluteString,
            "https://mcp.example.com/.well-known/oauth-protected-resource"
        )

        let bare = "Bearer resource_metadata=https://a.example/.well-known/oauth-protected-resource, error=\"invalid_token\""
        XCTAssertEqual(
            MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: bare)?.absoluteString,
            "https://a.example/.well-known/oauth-protected-resource"
        )

        XCTAssertNil(MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: "Bearer realm=\"mcp\""))
    }

    func testParseProtectedResourceMetadata() throws {
        let json = """
        {
          "resource": "https://mcp.example.com/mcp",
          "authorization_servers": ["https://auth.vendor.com"],
          "scopes_supported": ["mcp:read", "mcp:write"]
        }
        """
        let metadata = try MCPOAuthFlow.parseProtectedResourceMetadata(Data(json.utf8))
        XCTAssertEqual(metadata.resource?.absoluteString, "https://mcp.example.com/mcp")
        XCTAssertEqual(
            metadata.authorizationServers.map(\.absoluteString), ["https://auth.vendor.com"]
        )
        XCTAssertEqual(metadata.scopesSupported, ["mcp:read", "mcp:write"])

        XCTAssertThrowsError(
            try MCPOAuthFlow.parseProtectedResourceMetadata(Data("{}".utf8))
        )
    }

    func testDiscoveryFollowsTheChallengeToADifferentAuthHost() async throws {
        StubTransport.reset()
        StubTransport.route { request in
            switch request.url.absoluteString {
            case "https://mcp.example.com/.well-known/oauth-protected-resource":
                return .object([
                    "resource": "https://mcp.example.com/mcp",
                    "authorization_servers": .array(["https://auth.vendor.com"])
                ])
            case "https://auth.vendor.com/.well-known/oauth-authorization-server":
                return .object([
                    "issuer": "https://auth.vendor.com",
                    "authorization_endpoint": "https://auth.vendor.com/authorize",
                    "token_endpoint": "https://auth.vendor.com/token",
                    "registration_endpoint": "https://auth.vendor.com/register"
                ])
            default:
                return nil
            }
        }

        let discovered = try await MCPOAuthFlow.discover(
            for: URL(string: "https://mcp.example.com/mcp")!,
            wwwAuthenticate: #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#,
            urlSession: StubTransport.session()
        )

        XCTAssertEqual(discovered.authorizationServer.issuer, "https://auth.vendor.com")
        XCTAssertEqual(
            discovered.authorizationServer.tokenEndpoint.absoluteString,
            "https://auth.vendor.com/token"
        )
        XCTAssertEqual(discovered.resource?.resource?.absoluteString, "https://mcp.example.com/mcp")
    }
}

final class MCPOAuthTokenRequestTests: XCTestCase {

    private final class Provider: MCPOAuthClientProvider, @unchecked Sendable {
        let redirectURL = URL(string: "https://app.example.com/callback")!
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "https://app.example.com/callback")!],
            clientName: "Test"
        )
        private let lock = NSLock()
        private var storedTokens: MCPOAuthTokens?
        private var storedVerifier: String?
        private var storedState: String?
        var client: MCPOAuthClientInformation? = MCPOAuthClientInformation(clientID: "client-1")

        func tokens() async -> MCPOAuthTokens? { lock.withLock { storedTokens } }
        func saveTokens(_ tokens: MCPOAuthTokens) async { lock.withLock { storedTokens = tokens } }
        func clientInformation() async -> MCPOAuthClientInformation? { client }
        func saveClientInformation(_ info: MCPOAuthClientInformation) async { client = info }
        func saveCodeVerifier(_ verifier: String) async { lock.withLock { storedVerifier = verifier } }
        func codeVerifier() async -> String? { lock.withLock { storedVerifier } }
        func saveState(_ state: String) async { lock.withLock { storedState = state } }
        func state() async -> String? { lock.withLock { storedState } }
        func redirectToAuthorization(_ url: URL) async throws {}
    }

    private let metadata = MCPAuthorizationServerMetadata(
        issuer: "https://auth.vendor.com",
        authorizationEndpoint: URL(string: "https://auth.vendor.com/authorize")!,
        tokenEndpoint: URL(string: "https://auth.vendor.com/token")!
    )

    func testExchangeSendsTheResourceIndicator() async throws {
        StubTransport.reset(response: .object([
            "access_token": "at", "token_type": "Bearer", "expires_in": .number(3600)
        ]))
        let provider = Provider()
        await provider.saveCodeVerifier("verifier-123")

        _ = try await MCPOAuthFlow.exchangeCode(
            "code-abc",
            metadata: metadata,
            clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
            provider: provider,
            resource: URL(string: "https://mcp.example.com/mcp")!,
            urlSession: StubTransport.session()
        )

        let body = try XCTUnwrap(StubTransport.requests.first?.formBody)
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code-abc")
        XCTAssertEqual(body["code_verifier"], "verifier-123")
        XCTAssertEqual(
            body["resource"], "https://mcp.example.com/mcp",
            "RFC 8707 requires the resource indicator on the token request, not just authorize"
        )
    }

    func testRefreshSendsTheResourceIndicator() async throws {
        StubTransport.reset(response: .object(["access_token": "at2", "token_type": "Bearer"]))
        let provider = Provider()

        _ = try await MCPOAuthFlow.refresh(
            MCPOAuthTokens(
                accessToken: "old", refreshToken: "refresh-1", issuer: metadata.issuer
            ),
            metadata: metadata,
            clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
            provider: provider,
            resource: URL(string: "https://mcp.example.com/mcp")!,
            urlSession: StubTransport.session()
        )

        let body = try XCTUnwrap(StubTransport.requests.first?.formBody)
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "refresh-1")
        XCTAssertEqual(body["resource"], "https://mcp.example.com/mcp")
    }

    func testCallbackVerifiesStateAndRejectsMismatches() async throws {
        StubTransport.reset(response: .object(["access_token": "at", "token_type": "Bearer"]))
        let provider = Provider()
        await provider.saveCodeVerifier("verifier-123")
        await provider.saveState("state-xyz")

        do {
            _ = try await MCPOAuthFlow.handleCallback(
                URL(string: "https://app.example.com/callback?code=abc&state=WRONG")!,
                metadata: metadata,
                clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
                provider: provider,
                urlSession: StubTransport.session()
            )
            XCTFail("a mismatched state must be rejected")
        } catch let error as AIError {
            guard case .invalidRequest(let message) = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("state"), message)
        }

        let tokens = try await MCPOAuthFlow.handleCallback(
            URL(string: "https://app.example.com/callback?code=abc&state=state-xyz")!,
            metadata: metadata,
            clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
            provider: provider,
            urlSession: StubTransport.session()
        )
        XCTAssertEqual(tokens.accessToken, "at")
    }

    func testCallbackSurfacesServerErrors() async {
        let provider = Provider()
        do {
            _ = try await MCPOAuthFlow.handleCallback(
                URL(string: "https://app.example.com/callback?error=access_denied&error_description=User%20said%20no")!,
                metadata: metadata,
                clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
                provider: provider,
                urlSession: StubTransport.session()
            )
            XCTFail("expected the error parameter to surface")
        } catch let error as AIError {
            XCTAssertTrue("\(error)".contains("User said no"), "\(error)")
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }

    func testAuthorizationURLCarriesPKCEAndResource() async throws {
        let provider = Provider()
        let url = try await MCPOAuthFlow.startAuthorization(
            metadata: metadata,
            clientInformation: MCPOAuthClientInformation(clientID: "client-1"),
            provider: provider,
            resource: URL(string: "https://mcp.example.com/mcp")!,
            state: "state-1"
        )
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "state-1")
        XCTAssertEqual(value("resource"), "https://mcp.example.com/mcp")
        let verifier = await provider.codeVerifier()
        XCTAssertNotEqual(
            value("code_challenge"), verifier,
            "the challenge must be the SHA-256 of the verifier, never the verifier itself"
        )
        let stored = await provider.state()
        XCTAssertEqual(stored, "state-1", "state must be stored so the callback can be verified")
    }
}

final class MCPTransportAuthTests: XCTestCase {

    private final class Provider: MCPOAuthClientProvider, @unchecked Sendable {
        let redirectURL = URL(string: "https://app.example.com/callback")!
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "https://app.example.com/callback")!],
            clientName: "Test"
        )
        private let lock = NSLock()
        private var storedTokens: MCPOAuthTokens?
        init(tokens: MCPOAuthTokens?) { storedTokens = tokens }
        func tokens() async -> MCPOAuthTokens? { lock.withLock { storedTokens } }
        func saveTokens(_ tokens: MCPOAuthTokens) async { lock.withLock { storedTokens = tokens } }
        func clientInformation() async -> MCPOAuthClientInformation? {
            MCPOAuthClientInformation(clientID: "client-1")
        }
        func saveClientInformation(_ info: MCPOAuthClientInformation) async {}
        func saveCodeVerifier(_ verifier: String) async {}
        func codeVerifier() async -> String? { "verifier" }
        func redirectToAuthorization(_ url: URL) async throws {}
    }

    func testTransportAttachesTheAccessToken() async throws {
        StubTransport.reset(response: .object([
            "jsonrpc": "2.0", "id": .number(1), "result": .object([:])
        ]))
        let auth = MCPOAuthSession(
            serverURL: URL(string: "https://mcp.example.com/mcp")!,
            provider: Provider(tokens: MCPOAuthTokens(accessToken: "tok-123")),
            urlSession: StubTransport.session()
        )
        let transport = MCPHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            auth: auth,
            urlSession: StubTransport.session()
        )

        _ = try await transport.request(id: 1, method: "tools/list", params: .object([:]))
        XCTAssertEqual(
            StubTransport.requests.first?.authorization, "Bearer tok-123",
            "the transport must attach the OAuth token — this is what was missing entirely"
        )
    }

    func testTransportWithoutAuthSendsNoAuthorizationHeader() async throws {
        StubTransport.reset(response: .object([
            "jsonrpc": "2.0", "id": .number(1), "result": .object([:])
        ]))
        let transport = MCPHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            urlSession: StubTransport.session()
        )
        _ = try await transport.request(id: 1, method: "tools/list", params: .object([:]))
        XCTAssertNil(StubTransport.requests.first?.authorization)
    }

    func testUnauthorizedWithoutTokensAsksForTheBrowserFlow() async {
        StubTransport.reset()
        StubTransport.status = 401
        StubTransport.responseHeaders = [
            "WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#
        ]
        StubTransport.route { request in
            switch request.url.absoluteString {
            case "https://mcp.example.com/.well-known/oauth-protected-resource":
                return .object([
                    "resource": "https://mcp.example.com/mcp",
                    "authorization_servers": .array(["https://auth.vendor.com"])
                ])
            case "https://auth.vendor.com/.well-known/oauth-authorization-server":
                return .object([
                    "issuer": "https://auth.vendor.com",
                    "authorization_endpoint": "https://auth.vendor.com/authorize",
                    "token_endpoint": "https://auth.vendor.com/token"
                ])
            default:
                return nil
            }
        }

        let auth = MCPOAuthSession(
            serverURL: URL(string: "https://mcp.example.com/mcp")!,
            provider: Provider(tokens: nil),
            urlSession: StubTransport.session()
        )
        let transport = MCPHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            auth: auth,
            urlSession: StubTransport.session()
        )

        do {
            _ = try await transport.request(id: 1, method: "tools/list", params: .object([:]))
            XCTFail("expected an authorization-required error")
        } catch let error as AIError {
            guard case .authorizationRequired(let url) = error else {
                return XCTFail("expected authorizationRequired, got \(error)")
            }
            XCTAssertEqual(url.host, "auth.vendor.com")
            XCTAssertTrue(url.absoluteString.contains("code_challenge"), url.absoluteString)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }
}

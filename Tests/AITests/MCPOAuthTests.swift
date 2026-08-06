import XCTest
@testable import AI
#if canImport(CryptoKit)
import CryptoKit
#endif

private func expectedCodeChallenge(for verifier: String) -> String {
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLNoPad()
    #else
    return verifier
    #endif
}

private extension Data {
    func base64URLNoPad() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

actor MCPOAuthTestProvider: MCPOAuthClientProvider {
    nonisolated let redirectURL: URL
    nonisolated let clientMetadata: MCPOAuthClientMetadata

    private var storedTokens: MCPOAuthTokens?
    private var storedClientInfo: MCPOAuthClientInformation?
    private var storedVerifier: String?

    init(
        redirectURL: URL = URL(string: "test://callback")!,
        clientMetadata: MCPOAuthClientMetadata? = nil,
        clientInfo: MCPOAuthClientInformation? = nil,
        tokens: MCPOAuthTokens? = nil
    ) {
        self.redirectURL = redirectURL
        self.clientMetadata = clientMetadata ?? MCPOAuthClientMetadata(
            redirectURIs: [redirectURL], clientName: "Test Client"
        )
        self.storedClientInfo = clientInfo
        self.storedTokens = tokens
    }

    func tokens() async -> MCPOAuthTokens? { storedTokens }
    func saveTokens(_ tokens: MCPOAuthTokens) async { storedTokens = tokens }
    func clientInformation() async -> MCPOAuthClientInformation? { storedClientInfo }
    func saveClientInformation(_ info: MCPOAuthClientInformation) async { storedClientInfo = info }
    func saveCodeVerifier(_ verifier: String) async { storedVerifier = verifier }
    func codeVerifier() async -> String? { storedVerifier }
    func redirectToAuthorization(_ url: URL) async throws {}
}

final class MCPOAuthTests: XCTestCase {

    private let metadata = MCPAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example.com/token")!,
        registrationEndpoint: URL(string: "https://auth.example.com/register")!
    )
    private let clientInfo = MCPOAuthClientInformation(clientID: "abc123")

    func testBuildAuthorizationURLIncludesRequiredParams() throws {
        let url = try MCPOAuthFlow.buildAuthorizationURL(
            authorizationEndpoint: metadata.authorizationEndpoint,
            clientID: "abc123",
            redirectURI: URL(string: "test://callback")!,
            verifier: "test-verifier-value",
            scope: nil,
            resource: nil,
            state: "state-123"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "abc123")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("redirect_uri"), "test://callback")
        XCTAssertEqual(value("state"), "state-123")
        XCTAssertEqual(value("code_challenge"), expectedCodeChallenge(for: "test-verifier-value"))
        XCTAssertNil(value("scope"))
        XCTAssertNil(value("resource"))
    }

    func testBuildAuthorizationURLIncludesScopeAndResourceWhenProvided() throws {
        let url = try MCPOAuthFlow.buildAuthorizationURL(
            authorizationEndpoint: metadata.authorizationEndpoint,
            clientID: "abc123",
            redirectURI: URL(string: "test://callback")!,
            verifier: "v",
            scope: "tools:read",
            resource: URL(string: "https://mcp.example.com")!,
            state: "s"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "scope" })?.value, "tools:read")
        XCTAssertEqual(items.first(where: { $0.name == "resource" })?.value, "https://mcp.example.com")
    }

    func testStartAuthorizationSavesVerifierMatchingChallenge() async throws {
        let provider = MCPOAuthTestProvider()
        let url = try await MCPOAuthFlow.startAuthorization(
            metadata: metadata, clientInformation: clientInfo, provider: provider, state: "s1"
        )
        let storedVerifier = await provider.codeVerifier()
        let savedVerifier = try XCTUnwrap(storedVerifier)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let challenge = items.first(where: { $0.name == "code_challenge" })?.value
        XCTAssertEqual(challenge, expectedCodeChallenge(for: savedVerifier))
    }

    func testStartAuthorizationGeneratesDistinctVerifiersEachCall() async throws {
        let provider = MCPOAuthTestProvider()
        _ = try await MCPOAuthFlow.startAuthorization(metadata: metadata, clientInformation: clientInfo, provider: provider)
        let firstVerifier = await provider.codeVerifier()
        let first = try XCTUnwrap(firstVerifier)
        _ = try await MCPOAuthFlow.startAuthorization(metadata: metadata, clientInformation: clientInfo, provider: provider)
        let secondVerifier = await provider.codeVerifier()
        let second = try XCTUnwrap(secondVerifier)
        XCTAssertNotEqual(first, second)
    }

    func testStartAuthorizationThrowsWhenResponseTypeUnsupported() async throws {
        let unsupported = MCPAuthorizationServerMetadata(
            issuer: metadata.issuer, authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint, responseTypesSupported: ["token"]
        )
        let provider = MCPOAuthTestProvider()
        do {
            _ = try await MCPOAuthFlow.startAuthorization(metadata: unsupported, clientInformation: clientInfo, provider: provider)
            XCTFail("expected invalidRequest")
        } catch AIError.invalidRequest {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartAuthorizationThrowsWhenS256Unsupported() async throws {
        let unsupported = MCPAuthorizationServerMetadata(
            issuer: metadata.issuer, authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint, codeChallengeMethodsSupported: ["plain"]
        )
        let provider = MCPOAuthTestProvider()
        do {
            _ = try await MCPOAuthFlow.startAuthorization(metadata: unsupported, clientInformation: clientInfo, provider: provider)
            XCTFail("expected invalidRequest")
        } catch AIError.invalidRequest {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testParseAuthorizationServerMetadataFullDocument() throws {
        let json = #"""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token",
          "registration_endpoint": "https://auth.example.com/register",
          "response_types_supported": ["code"],
          "code_challenge_methods_supported": ["S256"]
        }
        """#.data(using: .utf8)!
        let parsed = try MCPOAuthFlow.parseAuthorizationServerMetadata(json)
        XCTAssertEqual(parsed.issuer, "https://auth.example.com")
        XCTAssertEqual(parsed.authorizationEndpoint, URL(string: "https://auth.example.com/authorize"))
        XCTAssertEqual(parsed.tokenEndpoint, URL(string: "https://auth.example.com/token"))
        XCTAssertEqual(parsed.registrationEndpoint, URL(string: "https://auth.example.com/register"))
        XCTAssertEqual(parsed.responseTypesSupported, ["code"])
        XCTAssertEqual(parsed.codeChallengeMethodsSupported, ["S256"])
    }

    func testParseAuthorizationServerMetadataDefaultsWhenOptionalFieldsMissing() throws {
        let json = #"""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token"
        }
        """#.data(using: .utf8)!
        let parsed = try MCPOAuthFlow.parseAuthorizationServerMetadata(json)
        XCTAssertNil(parsed.registrationEndpoint)
        XCTAssertEqual(parsed.responseTypesSupported, ["code"])
        XCTAssertEqual(parsed.codeChallengeMethodsSupported, ["S256"])
    }

    func testParseAuthorizationServerMetadataThrowsWhenTokenEndpointMissing() {
        let json = #"""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize"
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try MCPOAuthFlow.parseAuthorizationServerMetadata(json)) { error in
            guard case AIError.decoding = error else {
                XCTFail("expected AIError.decoding, got \(error)"); return
            }
        }
    }

    func testRegistrationRequestBodyShape() {
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "test://callback")!], clientName: "Test Client"
        )
        let body = MCPOAuthFlow.registrationRequestBody(clientMetadata)
        XCTAssertEqual(body["client_name"]?.stringValue, "Test Client")
        XCTAssertEqual(body["redirect_uris"]?.arrayValue?.first?.stringValue, "test://callback")
        XCTAssertEqual(body["grant_types"]?.arrayValue?.compactMap(\.stringValue), ["authorization_code", "refresh_token"])
        XCTAssertEqual(body["response_types"]?.arrayValue?.compactMap(\.stringValue), ["code"])
        XCTAssertEqual(body["token_endpoint_auth_method"]?.stringValue, "none")
        XCTAssertNil(body["scope"])
    }

    func testRegistrationRequestBodyIncludesScopeWhenProvided() {
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "test://callback")!], clientName: "Test Client", scope: "tools:read tools:write"
        )
        let body = MCPOAuthFlow.registrationRequestBody(clientMetadata)
        XCTAssertEqual(body["scope"]?.stringValue, "tools:read tools:write")
    }

    func testParseClientRegistrationWithSecret() throws {
        let json = #"{"client_id": "abc", "client_secret": "shh"}"#.data(using: .utf8)!
        let info = try MCPOAuthFlow.parseClientRegistration(json)
        XCTAssertEqual(info.clientID, "abc")
        XCTAssertEqual(info.clientSecret, "shh")
    }

    func testParseClientRegistrationWithoutSecret() throws {
        let json = #"{"client_id": "abc"}"#.data(using: .utf8)!
        let info = try MCPOAuthFlow.parseClientRegistration(json)
        XCTAssertEqual(info.clientID, "abc")
        XCTAssertNil(info.clientSecret)
    }

    func testParseClientRegistrationThrowsWhenClientIDMissing() {
        let json = #"{"client_secret": "shh"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try MCPOAuthFlow.parseClientRegistration(json)) { error in
            guard case AIError.decoding = error else {
                XCTFail("expected AIError.decoding, got \(error)"); return
            }
        }
    }

    func testEncodeFormBodyIsSortedAndPercentEncoded() {
        let params = [
            "grant_type": "authorization_code",
            "redirect_uri": "https://app.example.com/callback?x=1&y=2",
            "code": "abc 123"
        ]
        let encoded = String(decoding: MCPOAuthFlow.encodeFormBody(params), as: UTF8.self)
        let pairs = encoded.components(separatedBy: "&")

        XCTAssertEqual(pairs.count, params.count)

        var decoded: [String: String] = [:]
        var keysInOrder: [String] = []
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? ""
            decoded[key] = value
            keysInOrder.append(key)
        }

        XCTAssertEqual(decoded, params)
        XCTAssertEqual(keysInOrder, params.keys.sorted())
    }

    func testParseTokenResponseFull() throws {
        let json = #"""
        {"access_token": "at", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "rt", "scope": "tools"}
        """#.data(using: .utf8)!
        let tokens = try MCPOAuthFlow.parseTokenResponse(json)
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.tokenType, "Bearer")
        XCTAssertEqual(tokens.expiresIn, 3600)
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.scope, "tools")
    }

    func testParseTokenResponseDefaultsTokenTypeToBearer() throws {
        let json = #"{"access_token": "at"}"#.data(using: .utf8)!
        let tokens = try MCPOAuthFlow.parseTokenResponse(json)
        XCTAssertEqual(tokens.tokenType, "Bearer")
        XCTAssertNil(tokens.expiresIn)
        XCTAssertNil(tokens.refreshToken)
    }

    func testParseTokenResponseThrowsWhenAccessTokenMissing() {
        let json = #"{"token_type": "Bearer"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try MCPOAuthFlow.parseTokenResponse(json)) { error in
            guard case AIError.decoding = error else {
                XCTFail("expected AIError.decoding, got \(error)"); return
            }
        }
    }

    func testMergeRefreshedTokensCarriesOverPreviousRefreshTokenWhenOmitted() {
        let refreshed = MCPOAuthTokens(accessToken: "new-at", refreshToken: nil)
        let merged = MCPOAuthFlow.mergeRefreshedTokens(refreshed, previousRefreshToken: "old-rt")
        XCTAssertEqual(merged.accessToken, "new-at")
        XCTAssertEqual(merged.refreshToken, "old-rt")
    }

    func testMergeRefreshedTokensKeepsNewRefreshTokenWhenProvided() {
        let refreshed = MCPOAuthTokens(accessToken: "new-at", refreshToken: "new-rt")
        let merged = MCPOAuthFlow.mergeRefreshedTokens(refreshed, previousRefreshToken: "old-rt")
        XCTAssertEqual(merged.refreshToken, "new-rt")
    }

    func testTokensIsExpiredFalseWhenNoExpiresIn() {
        let tokens = MCPOAuthTokens(accessToken: "at", expiresIn: nil, obtainedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(tokens.isExpired)
    }

    func testTokensIsExpiredTrueBeyondSkewWindow() {
        let tokens = MCPOAuthTokens(accessToken: "at", expiresIn: 60, obtainedAt: Date().addingTimeInterval(-3600))
        XCTAssertTrue(tokens.isExpired)
    }

    func testTokensIsExpiredFalseWellWithinLifetime() {
        let tokens = MCPOAuthTokens(accessToken: "at", expiresIn: 3600, obtainedAt: Date())
        XCTAssertFalse(tokens.isExpired)
    }

    func testAuthorizationHeaderFormat() {
        let tokens = MCPOAuthTokens(accessToken: "at", tokenType: "Bearer")
        XCTAssertEqual(tokens.authorizationHeader, "Bearer at")
    }

    func testValidAccessTokenReturnsNilWhenNoTokensStored() async throws {
        let provider = MCPOAuthTestProvider()
        let result = try await MCPOAuthFlow.validAccessToken(for: URL(string: "https://mcp.example.com")!, provider: provider)
        XCTAssertNil(result)
    }

    func testValidAccessTokenReturnsStoredTokenWithoutRefreshWhenNotExpired() async throws {
        let fresh = MCPOAuthTokens(accessToken: "at", expiresIn: 3600, obtainedAt: Date())
        let provider = MCPOAuthTestProvider(tokens: fresh)
        let result = try await MCPOAuthFlow.validAccessToken(for: URL(string: "https://mcp.example.com")!, provider: provider)
        XCTAssertEqual(result?.accessToken, "at")
    }

    func testValidAccessTokenReturnsExpiredTokenAsIsWhenNoRefreshTokenAvailable() async throws {
        let expired = MCPOAuthTokens(
            accessToken: "at", expiresIn: 60, refreshToken: nil, obtainedAt: Date().addingTimeInterval(-3600)
        )
        let provider = MCPOAuthTestProvider(tokens: expired)
        let result = try await MCPOAuthFlow.validAccessToken(for: URL(string: "https://mcp.example.com")!, provider: provider)
        XCTAssertEqual(result?.accessToken, "at")
    }
}

final class MCPOAuthOriginValidationTests: XCTestCase {

    private final class Provider: MCPOAuthClientProvider, @unchecked Sendable {
        let redirectURL = URL(string: "https://app.example.com/callback")!
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "https://app.example.com/callback")!],
            clientName: "Test"
        )
        func tokens() async -> MCPOAuthTokens? { nil }
        func saveTokens(_ tokens: MCPOAuthTokens) async {}
        func clientInformation() async -> MCPOAuthClientInformation? { nil }
        func saveClientInformation(_ info: MCPOAuthClientInformation) async {}
        func saveCodeVerifier(_ verifier: String) async {}
        func codeVerifier() async -> String? { nil }
        func redirectToAuthorization(_ url: URL) async throws {}
    }

    private let server = URL(string: "https://mcp.example.com/sse")!

    func testResourceMetadataFromAnotherOriginIsRejected() {
        let header = #"Bearer resource_metadata="https://evil.example/prm""#
        XCTAssertNil(
            MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: header, serverURL: server),
            "a 401 must not be able to name another host as the metadata source"
        )
    }

    func testResourceMetadataFromTheSameOriginIsAccepted() {
        let header = #"Bearer resource_metadata="https://mcp.example.com/.well-known/x""#
        XCTAssertNotNil(
            MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: header, serverURL: server)
        )
    }

    func testCleartextResourceMetadataIsRejected() {
        let header = #"Bearer resource_metadata="http://mcp.example.com/prm""#
        XCTAssertNil(MCPOAuthFlow.resourceMetadataURL(fromWWWAuthenticate: header, serverURL: server))
    }

    func testProtectedResourceMetadataForAnotherAudienceIsRejected() {
        let json = #"{"resource":"https://evil.example","authorization_servers":["https://evil.example"]}"#
        XCTAssertThrowsError(
            try MCPOAuthFlow.parseProtectedResourceMetadata(Data(json.utf8), serverURL: server)
        )
    }

    func testAuthorizationServerMetadataWithMismatchedIssuerIsRejected() {
        let json = """
        {"issuer":"https://evil.example",
         "authorization_endpoint":"https://evil.example/auth",
         "token_endpoint":"https://evil.example/token"}
        """
        XCTAssertThrowsError(
            try MCPOAuthFlow.parseAuthorizationServerMetadata(
                Data(json.utf8), expectedIssuer: URL(string: "https://auth.example.com")!
            ),
            "RFC 8414 3.3: issuer must match the document's own origin"
        )
    }

    func testAuthorizationServerMetadataWithCleartextTokenEndpointIsRejected() {
        let json = """
        {"issuer":"https://auth.example.com",
         "authorization_endpoint":"https://auth.example.com/auth",
         "token_endpoint":"http://auth.example.com/token"}
        """
        XCTAssertThrowsError(
            try MCPOAuthFlow.parseAuthorizationServerMetadata(
                Data(json.utf8), expectedIssuer: URL(string: "https://auth.example.com")!
            )
        )
    }

    func testRefreshRefusesADifferentIssuerThanTheOneThatMintedTheToken() async {
        let tokens = MCPOAuthTokens(
            accessToken: "a", refreshToken: "r", issuer: "https://auth.example.com"
        )
        let attacker = MCPAuthorizationServerMetadata(
            issuer: "https://evil.example",
            authorizationEndpoint: URL(string: "https://evil.example/auth")!,
            tokenEndpoint: URL(string: "https://evil.example/token")!
        )
        do {
            _ = try await MCPOAuthFlow.refresh(
                tokens,
                metadata: attacker,
                clientInformation: MCPOAuthClientInformation(clientID: "c"),
                provider: Provider()
            )
            XCTFail("a refresh token must never be sent to a different issuer")
        } catch {}
    }
}

final class MCPOAuthIssuerBindingTests: XCTestCase {

    private final class Provider: MCPOAuthClientProvider, @unchecked Sendable {
        let redirectURL = URL(string: "https://app.example.com/callback")!
        let clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "https://app.example.com/callback")!],
            clientName: "Test"
        )
        var stored: MCPOAuthTokens?
        init(stored: MCPOAuthTokens? = nil) { self.stored = stored }
        func tokens() async -> MCPOAuthTokens? { stored }
        func saveTokens(_ tokens: MCPOAuthTokens) async { stored = tokens }
        func clientInformation() async -> MCPOAuthClientInformation? {
            MCPOAuthClientInformation(clientID: "c")
        }
        func saveClientInformation(_ info: MCPOAuthClientInformation) async {}
        func saveCodeVerifier(_ verifier: String) async {}
        func codeVerifier() async -> String? { nil }
        func redirectToAuthorization(_ url: URL) async throws {}
    }

    private let issuer = MCPAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: URL(string: "https://auth.example.com/auth")!,
        tokenEndpoint: URL(string: "https://auth.example.com/token")!
    )

    func testRefreshRefusesTokensWithNoRecordedIssuer() async {
        let legacy = MCPOAuthTokens(accessToken: "a", refreshToken: "r")
        XCTAssertNil(legacy.issuer, "tokens stored before binding carry no issuer")
        do {
            _ = try await MCPOAuthFlow.refresh(
                legacy,
                metadata: issuer,
                clientInformation: MCPOAuthClientInformation(clientID: "c"),
                provider: Provider()
            )
            XCTFail("an unbound refresh token must fail closed, not be waved through")
        } catch {}
    }

    func testExpiredUnboundTokensFallThroughToTheReauthorizePath() async throws {
        let legacy = MCPOAuthTokens(
            accessToken: "a", expiresIn: -1, refreshToken: "r",
            obtainedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(legacy.isExpired)
        // Returns the expired set instead of throwing, so the request 401s and
        // handleUnauthorized prompts for re-authorization.
        let result = try await MCPOAuthFlow.validAccessToken(
            for: URL(string: "https://mcp.example.com")!,
            provider: Provider(stored: legacy)
        )
        XCTAssertEqual(result?.accessToken, "a")
    }
}

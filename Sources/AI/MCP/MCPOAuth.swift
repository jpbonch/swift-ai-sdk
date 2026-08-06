import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public struct MCPOAuthTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var scope: String?
    public var obtainedAt: Date
    /// The `issuer` that minted these tokens. Refreshing checks it, so a
    /// re-discovery cannot send an existing refresh token somewhere new.
    /// Nil for tokens stored before this field existed.
    public var issuer: String?

    public init(
        accessToken: String, tokenType: String = "Bearer", expiresIn: Int? = nil,
        refreshToken: String? = nil, scope: String? = nil, obtainedAt: Date = Date(),
        issuer: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.obtainedAt = obtainedAt
        self.issuer = issuer
    }

    public var isExpired: Bool {
        guard let expiresIn else { return false }
        return Date() > obtainedAt.addingTimeInterval(TimeInterval(expiresIn) - 30)
    }

    public var authorizationHeader: String { "\(tokenType) \(accessToken)" }
}

public struct MCPOAuthClientInformation: Sendable, Hashable, Codable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct MCPOAuthClientMetadata: Sendable, Hashable {
    public var redirectURIs: [URL]
    public var clientName: String
    public var scope: String?
    public var grantTypes: [String]
    public var responseTypes: [String]
    public var tokenEndpointAuthMethod: String

    public init(
        redirectURIs: [URL], clientName: String, scope: String? = nil,
        grantTypes: [String] = ["authorization_code", "refresh_token"],
        responseTypes: [String] = ["code"],
        tokenEndpointAuthMethod: String = "none"
    ) {
        self.redirectURIs = redirectURIs
        self.clientName = clientName
        self.scope = scope
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    }
}

public struct MCPAuthorizationServerMetadata: Sendable, Hashable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var responseTypesSupported: [String]
    public var codeChallengeMethodsSupported: [String]

    public init(
        issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        responseTypesSupported: [String] = ["code"],
        codeChallengeMethodsSupported: [String] = ["S256"]
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.responseTypesSupported = responseTypesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
    }
}

public struct MCPProtectedResourceMetadata: Sendable, Hashable {
    public var resource: URL?
    public var authorizationServers: [URL]
    public var scopesSupported: [String]

    public init(
        resource: URL? = nil,
        authorizationServers: [URL] = [],
        scopesSupported: [String] = []
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}

public protocol MCPOAuthClientProvider: Sendable {
    var redirectURL: URL { get }
    var clientMetadata: MCPOAuthClientMetadata { get }

    func tokens() async -> MCPOAuthTokens?
    func saveTokens(_ tokens: MCPOAuthTokens) async

    func clientInformation() async -> MCPOAuthClientInformation?
    func saveClientInformation(_ info: MCPOAuthClientInformation) async

    func saveCodeVerifier(_ verifier: String) async
    func codeVerifier() async -> String?

    func saveState(_ state: String) async
    func state() async -> String?

    func redirectToAuthorization(_ url: URL) async throws
}

public extension MCPOAuthClientProvider {
    func saveState(_ state: String) async {}
    func state() async -> String? { nil }
}

public enum MCPOAuthFlow {

    /// Full MCP discovery: protected-resource metadata (from a 401 challenge when we have one)
    /// names the authorization server, and its metadata comes from that issuer — which is
    /// usually a different host than the MCP server itself.
    public static func discover(
        for serverURL: URL,
        wwwAuthenticate: String? = nil,
        urlSession: URLSession = .shared
    ) async throws -> (
        authorizationServer: MCPAuthorizationServerMetadata,
        resource: MCPProtectedResourceMetadata?
    ) {
        let resource = try? await discoverProtectedResourceMetadata(
            for: serverURL, wwwAuthenticate: wwwAuthenticate, urlSession: urlSession
        )

        if let issuer = resource?.authorizationServers.first {
            let metadata = try await discoverAuthorizationServerMetadata(
                issuer: issuer, urlSession: urlSession
            )
            return (metadata, resource)
        }

        let metadata = try await discoverAuthorizationServerMetadata(
            issuer: serverURL, urlSession: urlSession
        )
        return (metadata, resource)
    }

    public static func discoverProtectedResourceMetadata(
        for serverURL: URL,
        wwwAuthenticate: String? = nil,
        urlSession: URLSession = .shared
    ) async throws -> MCPProtectedResourceMetadata {
        var candidates: [URL] = []
        if let header = wwwAuthenticate,
           let advertised = Self.resourceMetadataURL(
               fromWWWAuthenticate: header, serverURL: serverURL
           ) {
            candidates.append(advertised)
        }
        candidates.append(contentsOf: wellKnownURLs("oauth-protected-resource", issuer: serverURL))

        for url in candidates {
            guard let data = try? await fetchJSON(at: url, urlSession: urlSession) else { continue }
            if let metadata = try? Self.parseProtectedResourceMetadata(data, serverURL: serverURL) {
                return metadata
            }
        }
        throw AIError.transport(
            "No OAuth protected-resource metadata for \(serverURL.absoluteString)."
        )
    }

    /// Scheme, host, and port. Two URLs share an origin when these all match.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port.map(String.init) ?? ""
        return "\(scheme)://\(host):\(port)"
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = origin(of: lhs), let right = origin(of: rhs) else { return false }
        return left == right
    }

    /// Loopback is allowed over plain HTTP so local development servers work;
    /// everything else has to be TLS, or the credentials this flow carries
    /// would cross the network in the clear.
    static func isSecureEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Parses `WWW-Authenticate: Bearer resource_metadata="https://…"` as sent with a 401.
    ///
    /// The value is attacker-controlled whenever the MCP server is: it arrives
    /// on a 401 from that server. RFC 9728 §3.3 requires it to be same-origin
    /// with the resource, and without that check a server can name any host as
    /// its authorization server and receive credentials minted by a different
    /// issuer.
    static func resourceMetadataURL(
        fromWWWAuthenticate header: String, serverURL: URL? = nil
    ) -> URL? {
        guard let range = header.range(of: "resource_metadata=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(header[range.upperBound...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            guard let end = value.firstIndex(of: "\"") else { return nil }
            value = String(value[..<end])
        } else if let end = value.firstIndex(where: { $0 == "," || $0 == " " }) {
            value = String(value[..<end])
        }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              isSecureEndpoint(url)
        else { return nil }
        if let serverURL, !sameOrigin(url, serverURL) { return nil }
        return url
    }

    /// `serverURL` is the MCP server this metadata is supposed to describe.
    /// Passing it enforces RFC 9728: the document's `resource` has to identify
    /// that server, and every advertised endpoint has to be TLS.
    static func parseProtectedResourceMetadata(
        _ data: Data, serverURL: URL? = nil
    ) throws -> MCPProtectedResourceMetadata {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let servers = (json["authorization_servers"]?.arrayValue ?? [])
            .compactMap { $0.stringValue.flatMap(URL.init(string:)) }
        guard !servers.isEmpty || json["resource"] != nil else {
            throw AIError.decoding(
                "Protected-resource metadata has neither `resource` nor `authorization_servers`."
            )
        }

        if let insecure = servers.first(where: { !isSecureEndpoint($0) }) {
            throw AIError.decoding(
                "Protected-resource metadata names a non-HTTPS authorization server "
                + "(\(insecure.absoluteString)). Credentials would cross the network in the clear."
            )
        }

        let resource = json["resource"]?.stringValue.flatMap(URL.init(string:))
        if let serverURL, let resource, !sameOrigin(resource, serverURL) {
            throw AIError.decoding(
                "Protected-resource metadata claims to describe \(resource.absoluteString), "
                + "which is not \(serverURL.absoluteString). Refusing it so a server cannot "
                + "redirect this flow at another audience."
            )
        }

        return MCPProtectedResourceMetadata(
            resource: resource,
            authorizationServers: servers,
            scopesSupported: json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    /// RFC 8414 well-known construction: for an issuer with a path, the well-known segment goes
    /// *between* the host and the path, with the origin-only form as a fallback.
    static func wellKnownURLs(_ suffix: String, issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            return []
        }
        let path = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.query = nil
        components.fragment = nil

        var urls: [URL] = []
        if !path.isEmpty, path != "/" {
            components.path = "/.well-known/\(suffix)\(path)"
            if let url = components.url { urls.append(url) }
        }
        components.path = "/.well-known/\(suffix)"
        if let url = components.url, !urls.contains(url) { urls.append(url) }
        return urls
    }

    public static func discoverAuthorizationServerMetadata(
        issuer: URL,
        urlSession: URLSession = .shared
    ) async throws -> MCPAuthorizationServerMetadata {
        guard isSecureEndpoint(issuer) else {
            throw AIError.transport(
                "Refusing to discover an OAuth authorization server over "
                + "\(issuer.scheme ?? "an unknown scheme") at \(issuer.absoluteString)."
            )
        }
        let candidates = wellKnownURLs("oauth-authorization-server", issuer: issuer)
            + wellKnownURLs("openid-configuration", issuer: issuer)
        for url in candidates {
            if let metadata = try? await fetchAuthorizationServerMetadata(
                at: url, issuer: issuer, urlSession: urlSession
            ) {
                return metadata
            }
        }
        throw AIError.transport(
            "Couldn't discover an OAuth authorization server for \(issuer.absoluteString). "
            + "Tried: \(candidates.map(\.absoluteString).joined(separator: ", "))."
        )
    }

    @available(*, deprecated, message: "Use discover(for:wwwAuthenticate:) — it follows the MCP protected-resource flow, which is required when the authorization server lives on a different host.")
    public static func discoverAuthorizationServerMetadata(
        for serverURL: URL,
        urlSession: URLSession = .shared
    ) async throws -> MCPAuthorizationServerMetadata {
        try await discoverAuthorizationServerMetadata(issuer: serverURL, urlSession: urlSession)
    }

    private static func fetchJSON(at url: URL, urlSession: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.transport("No metadata at \(url.absoluteString)")
        }
        return data
    }

    private static func fetchAuthorizationServerMetadata(
        at url: URL, issuer: URL? = nil, urlSession: URLSession
    ) async throws -> MCPAuthorizationServerMetadata {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.transport("No OAuth metadata at \(url.absoluteString)")
        }
        return try Self.parseAuthorizationServerMetadata(data, expectedIssuer: issuer)
    }

    /// `expectedIssuer` is the URL the document was fetched from. RFC 8414 §3.3
    /// requires the `issuer` inside it to match; without that check a metadata
    /// document can hand this flow a token endpoint on any host it likes.
    static func parseAuthorizationServerMetadata(
        _ data: Data, expectedIssuer: URL? = nil
    ) throws -> MCPAuthorizationServerMetadata {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let issuer = json["issuer"]?.stringValue,
              let authEndpoint = json["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
              let tokenEndpoint = json["token_endpoint"]?.stringValue.flatMap(URL.init(string:)) else {
            throw AIError.decoding("OAuth metadata is missing required fields (issuer, authorization_endpoint, token_endpoint).")
        }

        if let expectedIssuer, let declared = URL(string: issuer),
           !sameOrigin(declared, expectedIssuer) {
            throw AIError.decoding(
                "OAuth metadata fetched from \(expectedIssuer.absoluteString) declares issuer "
                + "\(issuer), which is a different origin (RFC 8414 §3.3)."
            )
        }

        let registrationEndpoint = json["registration_endpoint"]?.stringValue.flatMap(URL.init(string:))

        for endpoint in [authEndpoint, tokenEndpoint] + (registrationEndpoint.map { [$0] } ?? []) {
            guard isSecureEndpoint(endpoint) else {
                throw AIError.decoding(
                    "OAuth metadata names a non-HTTPS endpoint (\(endpoint.absoluteString)). "
                    + "The authorization code, PKCE verifier, and client secret would be sent "
                    + "in the clear."
                )
            }
        }
        let responseTypes = json["response_types_supported"]?.arrayValue?.compactMap(\.stringValue) ?? ["code"]
        let codeChallengeMethods = json["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue) ?? ["S256"]
        return MCPAuthorizationServerMetadata(
            issuer: issuer, authorizationEndpoint: authEndpoint, tokenEndpoint: tokenEndpoint,
            registrationEndpoint: registrationEndpoint,
            responseTypesSupported: responseTypes, codeChallengeMethodsSupported: codeChallengeMethods
        )
    }

    public static func registerClientIfNeeded(
        metadata: MCPAuthorizationServerMetadata,
        provider: any MCPOAuthClientProvider,
        urlSession: URLSession = .shared
    ) async throws -> MCPOAuthClientInformation {
        if let existing = await provider.clientInformation() { return existing }
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            throw AIError.invalidRequest(
                "This authorization server doesn't support Dynamic Client Registration; "
                + "supply client credentials for it manually."
            )
        }
        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Self.registrationRequestBody(provider.clientMetadata))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self))
        }
        let info = try Self.parseClientRegistration(data)
        await provider.saveClientInformation(info)
        return info
    }

    static func registrationRequestBody(_ clientMetadata: MCPOAuthClientMetadata) -> JSONValue {
        var object: [String: JSONValue] = [
            "redirect_uris": .array(clientMetadata.redirectURIs.map { .string($0.absoluteString) }),
            "client_name": .string(clientMetadata.clientName),
            "grant_types": .array(clientMetadata.grantTypes.map(JSONValue.string)),
            "response_types": .array(clientMetadata.responseTypes.map(JSONValue.string)),
            "token_endpoint_auth_method": .string(clientMetadata.tokenEndpointAuthMethod)
        ]
        if let scope = clientMetadata.scope {
            object["scope"] = .string(scope)
        }
        return .object(object)
    }

    static func parseClientRegistration(_ data: Data) throws -> MCPOAuthClientInformation {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let clientID = json["client_id"]?.stringValue else {
            throw AIError.decoding("Client registration response is missing client_id.")
        }
        return MCPOAuthClientInformation(clientID: clientID, clientSecret: json["client_secret"]?.stringValue)
    }

    public static func startAuthorization(
        metadata: MCPAuthorizationServerMetadata,
        clientInformation: MCPOAuthClientInformation,
        provider: any MCPOAuthClientProvider,
        resource: URL? = nil,
        state: String = UUID().uuidString
    ) async throws -> URL {
        guard metadata.responseTypesSupported.contains("code") else {
            throw AIError.invalidRequest("Authorization server \(metadata.issuer) doesn't support the 'code' response type.")
        }
        guard metadata.codeChallengeMethodsSupported.contains("S256") else {
            throw AIError.invalidRequest("Authorization server \(metadata.issuer) doesn't support PKCE's S256 challenge method.")
        }

        let verifier = try Self.makeCodeVerifier()
        await provider.saveCodeVerifier(verifier)
        await provider.saveState(state)

        return try Self.buildAuthorizationURL(
            authorizationEndpoint: metadata.authorizationEndpoint,
            clientID: clientInformation.clientID,
            redirectURI: provider.redirectURL,
            verifier: verifier,
            scope: provider.clientMetadata.scope,
            resource: resource,
            state: state
        )
    }

    static func buildAuthorizationURL(
        authorizationEndpoint: URL,
        clientID: String,
        redirectURI: URL,
        verifier: String,
        scope: String?,
        resource: URL?,
        state: String
    ) throws -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_challenge", value: try Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        if let scope {
            query.append(URLQueryItem(name: "scope", value: scope))
        }
        if let resource {
            query.append(URLQueryItem(name: "resource", value: resource.absoluteString))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw AIError.invalidRequest("Couldn't build an authorization URL.")
        }
        return url
    }

    public static func exchangeCode(
        _ code: String,
        metadata: MCPAuthorizationServerMetadata,
        clientInformation: MCPOAuthClientInformation,
        provider: any MCPOAuthClientProvider,
        resource: URL? = nil,
        urlSession: URLSession = .shared
    ) async throws -> MCPOAuthTokens {
        guard let verifier = await provider.codeVerifier() else {
            throw AIError.invalidRequest("No PKCE code verifier on hand -- did startAuthorization run in this session?")
        }
        var params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": provider.redirectURL.absoluteString,
            "code_verifier": verifier
        ]
        if let resource { params["resource"] = resource.absoluteString }
        let tokens = try await Self.requestTokens(
            metadata: metadata, clientInformation: clientInformation, params: params, urlSession: urlSession
        )
        await provider.saveTokens(tokens)
        return tokens
    }

    /// Completes an interactive flow from the redirect the browser came back with:
    /// verifies `state` against what `startAuthorization` stored, then exchanges the code.
    public static func handleCallback(
        _ callbackURL: URL,
        metadata: MCPAuthorizationServerMetadata,
        clientInformation: MCPOAuthClientInformation,
        provider: any MCPOAuthClientProvider,
        resource: URL? = nil,
        urlSession: URLSession = .shared
    ) async throws -> MCPOAuthTokens {
        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }

        if let error = value("error") {
            let description = value("error_description") ?? error
            throw AIError.transport("Authorization failed: \(description)")
        }
        guard let code = value("code") else {
            throw AIError.invalidRequest("Authorization callback has no `code` parameter.")
        }
        if let expected = await provider.state() {
            guard value("state") == expected else {
                throw AIError.invalidRequest(
                    "Authorization callback `state` does not match the value we sent — "
                    + "rejecting the response."
                )
            }
        }
        return try await exchangeCode(
            code, metadata: metadata, clientInformation: clientInformation,
            provider: provider, resource: resource, urlSession: urlSession
        )
    }

    public static func refresh(
        _ tokens: MCPOAuthTokens,
        metadata: MCPAuthorizationServerMetadata,
        clientInformation: MCPOAuthClientInformation,
        provider: any MCPOAuthClientProvider,
        resource: URL? = nil,
        urlSession: URLSession = .shared
    ) async throws -> MCPOAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw AIError.invalidRequest("This token set has no refresh_token.")
        }
        // The last line of defence for the whole discovery chain. Even if a
        // server talks this client into rediscovering a different authorization
        // server, an existing refresh token only ever goes back to the issuer
        // that minted it. An unknown issuer fails closed rather than being
        // waved through, so the check cannot be sidestepped by dropping the
        // field.
        guard let minted = tokens.issuer else {
            throw AIError.invalidRequest(
                "These tokens record no issuer, so there is nothing to check the refresh "
                + "against. They were stored before issuer binding existed — re-authorize "
                + "to mint a set that carries one."
            )
        }
        guard minted == metadata.issuer else {
            throw AIError.invalidRequest(
                "These tokens were issued by \(minted), but the refresh would go to "
                + "\(metadata.issuer). Refusing to hand a refresh token to a different issuer."
            )
        }
        var params = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        if let resource { params["resource"] = resource.absoluteString }
        let refreshed = try await Self.requestTokens(
            metadata: metadata, clientInformation: clientInformation, params: params, urlSession: urlSession
        )
        let merged = Self.mergeRefreshedTokens(refreshed, previousRefreshToken: refreshToken)
        await provider.saveTokens(merged)
        return merged
    }

    static func mergeRefreshedTokens(_ refreshed: MCPOAuthTokens, previousRefreshToken: String?) -> MCPOAuthTokens {
        var merged = refreshed
        if merged.refreshToken == nil { merged.refreshToken = previousRefreshToken }
        return merged
    }

    public static func validAccessToken(
        for serverURL: URL,
        provider: any MCPOAuthClientProvider,
        urlSession: URLSession = .shared
    ) async throws -> MCPOAuthTokens? {
        guard let tokens = await provider.tokens() else { return nil }
        guard tokens.isExpired else { return tokens }
        guard tokens.refreshToken != nil, let clientInformation = await provider.clientInformation() else {
            return tokens
        }
        // Tokens stored before issuer binding cannot be refreshed safely. Hand
        // back the expired set rather than throwing here: the request fails
        // with a 401, and `handleUnauthorized` turns that into a re-authorize
        // prompt, which is the outcome the caller wants anyway.
        guard tokens.issuer != nil else { return tokens }
        let discovered = try await Self.discover(for: serverURL, urlSession: urlSession)
        return try await Self.refresh(
            tokens, metadata: discovered.authorizationServer,
            clientInformation: clientInformation, provider: provider,
            resource: discovered.resource?.resource ?? serverURL,
            urlSession: urlSession
        )
    }

    private static func requestTokens(
        metadata: MCPAuthorizationServerMetadata,
        clientInformation: MCPOAuthClientInformation,
        params: [String: String],
        urlSession: URLSession
    ) async throws -> MCPOAuthTokens {
        var body = params
        body["client_id"] = clientInformation.clientID
        if let secret = clientInformation.clientSecret {
            body["client_secret"] = secret
        }
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeFormBody(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self))
        }
        // Stamp the issuer so a later refresh can verify it hasn't been pointed
        // somewhere else.
        var tokens = try Self.parseTokenResponse(data)
        tokens.issuer = metadata.issuer
        return tokens
    }

    static func encodeFormBody(_ params: [String: String]) -> Data {
        params.keys.sorted().map { key -> String in
            let value = params[key]!
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }

    static func parseTokenResponse(_ data: Data) throws -> MCPOAuthTokens {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let accessToken = json["access_token"]?.stringValue else {
            throw AIError.decoding("Token response is missing access_token.")
        }
        return MCPOAuthTokens(
            accessToken: accessToken,
            tokenType: json["token_type"]?.stringValue ?? "Bearer",
            expiresIn: json["expires_in"]?.intValue,
            refreshToken: json["refresh_token"]?.stringValue,
            scope: json["scope"]?.stringValue
        )
    }

    /// Throws rather than falling back to the zero-filled buffer: a verifier
    /// that isn't random is a constant, and a constant verifier means PKCE
    /// protects nothing while still appearing to work.
    private static func makeCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AIError.transport(
                "Couldn't draw random bytes for the PKCE code verifier "
                + "(SecRandomCopyBytes returned \(status))."
            )
        }
        #else
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return Self.base64URLEncode(Data(bytes))
    }

    static func codeChallenge(for verifier: String) throws -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Self.base64URLEncode(Data(digest))
        #else
        throw AIError.unsupportedFunctionality(
            "PKCE S256 needs CryptoKit, which this platform does not provide. "
            + "Sending the plain verifier would be rejected by the authorization server."
        )
        #endif
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static var urlQueryValueAllowed: CharacterSet {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }
}

/// Ties a provider to one MCP server: mints headers, discovers lazily, refreshes on 401,
/// and tells the app when a browser round-trip is required.
public actor MCPOAuthSession {
    public let serverURL: URL
    private let provider: any MCPOAuthClientProvider
    private let urlSession: URLSession

    private var authorizationServer: MCPAuthorizationServerMetadata?
    private var protectedResource: MCPProtectedResourceMetadata?

    public init(
        serverURL: URL,
        provider: any MCPOAuthClientProvider,
        urlSession: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.provider = provider
        self.urlSession = urlSession
    }

    /// The `Authorization` value for the next request, or nil when we have no token yet.
    public func authorizationHeader() async throws -> String? {
        guard let tokens = try await MCPOAuthFlow.validAccessToken(
            for: serverURL, provider: provider, urlSession: urlSession
        ) else { return nil }
        return tokens.authorizationHeader
    }

    /// Called by a transport on a 401. Refreshes when possible and reports whether the caller
    /// should retry; otherwise throws `.authorizationRequired` carrying the URL to open.
    public func handleUnauthorized(wwwAuthenticate: String?) async throws -> Bool {
        let discovered = try await discoverIfNeeded(wwwAuthenticate: wwwAuthenticate)

        if let tokens = await provider.tokens(), tokens.refreshToken != nil,
           let clientInformation = await provider.clientInformation() {
            let refreshed = try? await MCPOAuthFlow.refresh(
                tokens, metadata: discovered.authorizationServer,
                clientInformation: clientInformation, provider: provider,
                resource: resourceIndicator, urlSession: urlSession
            )
            if refreshed != nil { return true }
        }

        throw AIError.authorizationRequired(url: try await authorizationURL())
    }

    /// Begins the interactive flow: discovery, registration if the server supports it, and a
    /// PKCE authorization URL. Also asks the provider to open it, if it can.
    public func authorizationURL() async throws -> URL {
        let discovered = try await discoverIfNeeded(wwwAuthenticate: nil)
        let clientInformation = try await MCPOAuthFlow.registerClientIfNeeded(
            metadata: discovered.authorizationServer, provider: provider, urlSession: urlSession
        )
        let url = try await MCPOAuthFlow.startAuthorization(
            metadata: discovered.authorizationServer,
            clientInformation: clientInformation,
            provider: provider,
            resource: resourceIndicator
        )
        try? await provider.redirectToAuthorization(url)
        return url
    }

    /// Finishes the flow with the redirect URL the browser returned to.
    @discardableResult
    public func complete(callbackURL: URL) async throws -> MCPOAuthTokens {
        let discovered = try await discoverIfNeeded(wwwAuthenticate: nil)
        guard let clientInformation = await provider.clientInformation() else {
            throw AIError.invalidRequest(
                "No client registration on hand — call authorizationURL() before complete(callbackURL:)."
            )
        }
        return try await MCPOAuthFlow.handleCallback(
            callbackURL,
            metadata: discovered.authorizationServer,
            clientInformation: clientInformation,
            provider: provider,
            resource: resourceIndicator,
            urlSession: urlSession
        )
    }

    private var resourceIndicator: URL {
        protectedResource?.resource ?? serverURL
    }

    private func discoverIfNeeded(
        wwwAuthenticate: String?
    ) async throws -> (
        authorizationServer: MCPAuthorizationServerMetadata,
        resource: MCPProtectedResourceMetadata?
    ) {
        if let authorizationServer, wwwAuthenticate == nil {
            return (authorizationServer, protectedResource)
        }
        let discovered = try await MCPOAuthFlow.discover(
            for: serverURL, wwwAuthenticate: wwwAuthenticate, urlSession: urlSession
        )
        authorizationServer = discovered.authorizationServer
        protectedResource = discovered.resource
        return discovered
    }
}

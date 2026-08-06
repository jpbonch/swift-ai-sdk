import XCTest
@testable import AI

#if os(macOS) || os(Linux)
final class MCPOAuthLiveServerTests: XCTestCase {

    private static let serverSource = """
    import sys, json, hashlib, base64, secrets
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse, parse_qs, urlencode

    CLIENT_ID = "test-client-id"
    CLIENT_SECRET = "test-client-secret"
    codes = {}
    issued_refresh = set()

    def b64url(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def _json(self, obj, status=200):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/.well-known/oauth-authorization-server":
                base = "http://127.0.0.1:%d" % PORT
                self._json({
                    "issuer": base,
                    "authorization_endpoint": base + "/authorize",
                    "token_endpoint": base + "/token",
                    "registration_endpoint": base + "/register",
                    "response_types_supported": ["code"],
                    "code_challenge_methods_supported": ["S256"]
                })
            elif parsed.path == "/authorize":
                qs = parse_qs(parsed.query)
                code = secrets.token_urlsafe(16)
                codes[code] = {
                    "code_challenge": qs["code_challenge"][0],
                    "client_id": qs["client_id"][0],
                    "redirect_uri": qs["redirect_uri"][0]
                }
                redirect = qs["redirect_uri"][0] + "?" + urlencode({
                    "code": code, "state": qs.get("state", [""])[0]
                })
                self.send_response(302)
                self.send_header("Location", redirect)
                self.end_headers()
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode()
            parsed = urlparse(self.path)
            if parsed.path == "/register":
                self._json({"client_id": CLIENT_ID, "client_secret": CLIENT_SECRET})
            elif parsed.path == "/token":
                form = parse_qs(raw)
                grant_type = form.get("grant_type", [""])[0]
                if form.get("client_id", [""])[0] != CLIENT_ID:
                    self._json({"error": "invalid_client"}, 401)
                    return
                if grant_type == "authorization_code":
                    code = form.get("code", [""])[0]
                    verifier = form.get("code_verifier", [""])[0]
                    entry = codes.get(code)
                    if entry is None:
                        self._json({"error": "invalid_grant"}, 400)
                        return
                    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
                    if challenge != entry["code_challenge"]:
                        self._json({"error": "invalid_grant"}, 400)
                        return
                    refresh = secrets.token_urlsafe(16)
                    issued_refresh.add(refresh)
                    self._json({
                        "access_token": secrets.token_urlsafe(16),
                        "token_type": "Bearer",
                        "expires_in": 3600,
                        "refresh_token": refresh
                    })
                elif grant_type == "refresh_token":
                    refresh = form.get("refresh_token", [""])[0]
                    if refresh not in issued_refresh:
                        self._json({"error": "invalid_grant"}, 400)
                        return
                    self._json({
                        "access_token": secrets.token_urlsafe(16),
                        "token_type": "Bearer",
                        "expires_in": 3600
                    })
                else:
                    self._json({"error": "unsupported_grant_type"}, 400)
            else:
                self.send_response(404)
                self.end_headers()

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    PORT = srv.server_address[1]
    print(PORT, flush=True)
    srv.serve_forever()
    """

    private func startServer() throws -> (process: Process, baseURL: URL) {
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
            && !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
            && !FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3") {
            throw XCTSkip("python3 not available for the OAuth fixture server")
        }
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("mcp_oauth_fixture_\(UUID().uuidString).py")
        try Self.serverSource.write(to: path, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", path.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()

        var portData = Data()
        while !String(decoding: portData, as: UTF8.self).contains("\n") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            portData.append(chunk)
        }
        let port = String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        return (process, baseURL)
    }

    private final class RedirectCapturingDelegate: NSObject, URLSessionTaskDelegate {
        private(set) nonisolated(unsafe) var capturedURL: URL?

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            capturedURL = request.url
            completionHandler(nil)
        }
    }

    private func authorizationCode(
        for authURL: URL
    ) async throws -> (code: String, state: String?) {
        let redirectDelegate = RedirectCapturingDelegate()
        let noFollowSession = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        _ = try? await noFollowSession.data(from: authURL)
        let redirectedTo = try XCTUnwrap(redirectDelegate.capturedURL)
        let items = try XCTUnwrap(URLComponents(url: redirectedTo, resolvingAgainstBaseURL: false)?.queryItems)
        let code = try XCTUnwrap(items.first(where: { $0.name == "code" })?.value)
        return (code, items.first(where: { $0.name == "state" })?.value)
    }

    func testFullOAuthFlowAgainstRealLocalServer() async throws {
        let (process, baseURL) = try startServer()
        defer { process.terminate() }

        let session = URLSession(configuration: .ephemeral)
        let provider = MCPOAuthTestProvider(redirectURL: URL(string: "test://callback")!)

        let metadata = try await MCPOAuthFlow.discoverAuthorizationServerMetadata(for: baseURL, urlSession: session)
        XCTAssertEqual(metadata.tokenEndpoint.path, "/token")
        XCTAssertEqual(metadata.registrationEndpoint?.path, "/register")

        let clientInfo = try await MCPOAuthFlow.registerClientIfNeeded(metadata: metadata, provider: provider, urlSession: session)
        XCTAssertEqual(clientInfo.clientID, "test-client-id")
        XCTAssertEqual(clientInfo.clientSecret, "test-client-secret")

        let authURL = try await MCPOAuthFlow.startAuthorization(
            metadata: metadata, clientInformation: clientInfo, provider: provider, state: "xyz-state"
        )
        let (code, state) = try await authorizationCode(for: authURL)
        XCTAssertEqual(state, "xyz-state")

        let tokens = try await MCPOAuthFlow.exchangeCode(
            code, metadata: metadata, clientInformation: clientInfo, provider: provider, urlSession: session
        )
        XCTAssertFalse(tokens.accessToken.isEmpty)
        let issuedRefreshToken = try XCTUnwrap(tokens.refreshToken)

        let refreshed = try await MCPOAuthFlow.refresh(
            tokens, metadata: metadata, clientInformation: clientInfo, provider: provider, urlSession: session
        )
        XCTAssertNotEqual(refreshed.accessToken, tokens.accessToken)
        XCTAssertEqual(refreshed.refreshToken, issuedRefreshToken)

        let savedTokens = await provider.tokens()
        XCTAssertEqual(savedTokens?.accessToken, refreshed.accessToken)
    }

    func testExchangeCodeFailsWithWrongVerifier() async throws {
        let (process, baseURL) = try startServer()
        defer { process.terminate() }

        let session = URLSession(configuration: .ephemeral)
        let provider = MCPOAuthTestProvider(redirectURL: URL(string: "test://callback")!)

        let metadata = try await MCPOAuthFlow.discoverAuthorizationServerMetadata(for: baseURL, urlSession: session)
        let clientInfo = try await MCPOAuthFlow.registerClientIfNeeded(metadata: metadata, provider: provider, urlSession: session)
        let authURL = try await MCPOAuthFlow.startAuthorization(metadata: metadata, clientInformation: clientInfo, provider: provider)
        let (code, _) = try await authorizationCode(for: authURL)

        await provider.saveCodeVerifier("a-completely-different-verifier")

        do {
            _ = try await MCPOAuthFlow.exchangeCode(
                code, metadata: metadata, clientInformation: clientInfo, provider: provider, urlSession: session
            )
            XCTFail("expected the server to reject a mismatched PKCE verifier")
        } catch AIError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }
    }
}
#endif

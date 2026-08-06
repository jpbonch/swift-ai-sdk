import AI
import Foundation

func example_mcpHTTP() async throws {
    let mcp = MCPClient(transport: MCPHTTPTransport(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!
    ))
    try await mcp.connect()
    defer { Task { await mcp.close() } }

    let result = try await generateText(
        model: AnthropicModel("claude-sonnet-5"),
        prompt: "Use the DeepWiki tools to explain how the modelcontextprotocol/modelcontextprotocol repository is organized.",
        tools: try await mcp.tools(),
        stopWhen: [stepCountIs(5)]
    )
    print(result.text)
}

func example_mcpDeepWikiDirect() async throws {
    let mcp = MCPClient(transport: MCPHTTPTransport(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!
    ))
    try await mcp.connect()
    defer { Task { await mcp.close() } }

    let tools = try await mcp.tools()
    print("DeepWiki tools: \(tools.map(\.name))")

    let structure = try await mcp.callTool(
        name: "read_wiki_structure",
        arguments: ["repoName": "modelcontextprotocol/modelcontextprotocol"]
    )
    print(structure.stringValue ?? "\(structure)")
}

#if os(macOS) || os(Linux)
func example_mcpStdio() async throws {
    let mcp = MCPClient(transport: MCPStdioTransport(
        command: "npx",
        arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        requestTimeout: 30
    ))
    try await mcp.connect()
    defer { Task { await mcp.close() } }

    let result = try await generateText(
        model: AnthropicModel("claude-sonnet-5"),
        prompt: "List the files in /tmp and summarize what you find.",
        tools: try await mcp.tools(),
        stopWhen: [stepCountIs(5)]
    )
    print(result.text)
}
#endif

func example_mcpLegacySSE() async throws {
    let mcp = MCPClient(transport: MCPSSETransport(
        url: URL(string: "https://legacy.example.com/sse")!
    ))
    try await mcp.connect()
    defer { Task { await mcp.close() } }

    let tools = try await mcp.tools()
    print("discovered \(tools.count) tools: \(tools.map(\.name))")
}

actor InMemoryMCPOAuthProvider: MCPOAuthClientProvider {
    nonisolated let redirectURL: URL
    nonisolated let clientMetadata: MCPOAuthClientMetadata

    private var storedTokens: MCPOAuthTokens?
    private var storedClientInfo: MCPOAuthClientInformation?
    private var storedVerifier: String?
    private var storedState: String?

    init(redirectURL: URL, clientName: String = "swift-ai-sdk") {
        self.redirectURL = redirectURL
        self.clientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [redirectURL], clientName: clientName
        )
    }

    func tokens() async -> MCPOAuthTokens? { storedTokens }
    func saveTokens(_ tokens: MCPOAuthTokens) async { storedTokens = tokens }
    func clientInformation() async -> MCPOAuthClientInformation? { storedClientInfo }
    func saveClientInformation(_ info: MCPOAuthClientInformation) async { storedClientInfo = info }
    func saveCodeVerifier(_ verifier: String) async { storedVerifier = verifier }
    func codeVerifier() async -> String? { storedVerifier }
    func saveState(_ state: String) async { storedState = state }
    func state() async -> String? { storedState }
    func redirectToAuthorization(_ url: URL) async throws {}
}

func example_mcpOAuth() async throws {
    let serverURL = URL(string: "https://mcp.notion.com/mcp")!
    let provider = InMemoryMCPOAuthProvider(
        redirectURL: URL(string: "http://127.0.0.1:8765/callback")!
    )
    let auth = MCPOAuthSession(serverURL: serverURL, provider: provider)
    let mcp = MCPClient(transport: MCPHTTPTransport(url: serverURL, auth: auth))
    defer { Task { await mcp.close() } }

    do {
        let tools = try await mcp.tools()
        print("already signed in - \(tools.count) tools")
        return
    } catch AIError.authorizationRequired(let url) {
        print("Open this to sign in:\n\(url.absoluteString)\n")
        print("Then paste the full URL your browser was redirected to:")
        guard let pasted = readLine(strippingNewline: true).flatMap(URL.init(string:)) else {
            print("no callback URL provided")
            return
        }
        try await auth.complete(callbackURL: pasted)
    }

    let tools = try await mcp.tools()
    print("signed in - \(tools.count) tools: \(tools.map(\.name))")
}

func example_mcpRugPullDetection() async throws {
    let mcp = MCPClient(transport: MCPHTTPTransport(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!
    ))
    try await mcp.connect()
    defer { Task { await mcp.close() } }

    let approved = fingerprintTools(try await mcp.tools())

    let latest = try await mcp.tools()
    let drift = detectToolDrift(fingerprintTools(latest), baseline: approved)
    guard !drift.hasDrift else {
        print("tool definitions drifted - changed: \(drift.changed), added: \(drift.added)")
        return
    }

    let result = try await generateText(
        model: AnthropicModel("claude-sonnet-5"),
        prompt: "Ask DeepWiki what the modelcontextprotocol/modelcontextprotocol repository documents about transports.",
        tools: latest,
        stopWhen: [stepCountIs(5)]
    )
    print(result.text)
}

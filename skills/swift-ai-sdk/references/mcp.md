# MCP: client, transports, OAuth, drift detection

`MCPClient` turns a Model Context Protocol server's tools into `[any AIToolProtocol]` you pass straight to `generateText` / `streamText` / `Agent`. `import AI`.

```swift
let mcp = MCPClient(transport: MCPHTTPTransport(url: URL(string: "https://mcp.deepwiki.com/mcp")!))
try await mcp.connect()
defer { Task { await mcp.close() } }

let result = try await generateText(model: model, prompt: "…", tools: try await mcp.tools())
```

`connect()` is idempotent and implicit: `tools()` and `callTool(name:arguments:)` call it themselves. `tools()` follows `nextCursor` pagination to the end. `callTool` returns `structuredContent` when present, otherwise the joined text content, and throws `AIError.transport` when the server sets `isError`.

Tools from a server are `isDynamic` automatically, so a UI can tell them from compiled-in tools.

## Transports

| Transport | Use for | Notes |
| --- | --- | --- |
| `MCPHTTPTransport(url:headers:auth:urlSession:)` | Current spec (Streamable HTTP) | Carries `mcp-session-id` across calls; parses both JSON and `text/event-stream` replies |
| `MCPStdioTransport(command:arguments:requestTimeout:)` | Local server as a subprocess | Newline-delimited JSON-RPC over pipes |
| `MCPSSETransport(url:headers:auth:urlSession:requestTimeout:)` | Legacy HTTP+SSE servers | Long-lived `GET` event stream plus a `POST` message endpoint |

All three conform to `MCPTransport` (`request(id:method:params:)`, `notify(method:)`, `close()`), so they are drop-in swaps.

## OAuth

Hosted servers usually sit behind OAuth rather than a static bearer token. Build an `MCPOAuthSession` and hand it to the transport as `auth:`; `MCPHTTPTransport` and `MCPSSETransport` both take it.

```swift
let auth = MCPOAuthSession(serverURL: serverURL, provider: myProvider)
let mcp = MCPClient(transport: MCPHTTPTransport(url: serverURL, auth: auth))
```

The transport attaches the access token, and on a `401` refreshes and retries once. If it cannot refresh it throws `AIError.authorizationRequired(url:)` carrying the URL to open. Hand the browser's redirect back to `auth.complete(callbackURL:)`.

You implement `MCPOAuthClientProvider`: it owns `redirectURL`, `clientMetadata` (for dynamic client registration), and storage for tokens, the registered client, the PKCE verifier, and the CSRF `state`. `saveState` / `state` have no-op defaults, so implement them or callback verification silently passes. Persist tokens and client information for sign-in to survive a relaunch.

What the session does on demand, so you do not have to:

- **Discovery chain.** The `401`'s `WWW-Authenticate` names the protected-resource metadata document (RFC 9728), which names the authorization server. That server is **commonly a different host** than the MCP server, so the single-host shortcut most clients take fails.
- **RFC 8414 well-known URLs.** The issuer path is preserved (`/tenant/acme` → `/.well-known/oauth-authorization-server/tenant/acme`), with the origin-only form as fallback.
- **PKCE `S256`**, and a thrown error rather than a silent downgrade to `plain` where CryptoKit is unavailable.
- **RFC 8707 `resource` indicator** on the authorization, token, and refresh requests.
- **`state` verification** on the callback before the code is exchanged.
- **Dynamic client registration** when the server advertises a `registration_endpoint`.

`MCPOAuthFlow` exposes each step individually (`discover`, `registerClientIfNeeded`, `startAuthorization`, `handleCallback`, `refresh`, `validAccessToken`) for apps that drive the flow themselves.

Data types the provider stores: `MCPOAuthTokens` (with `isExpired` and `authorizationHeader`), `MCPOAuthClientInformation`, `MCPOAuthClientMetadata`, `MCPAuthorizationServerMetadata`, `MCPProtectedResourceMetadata`.

## Drift detection (rug pull)

A server can change a tool's definition after the user approved it. Fingerprint what you approved, then compare later:

```swift
let approved = fingerprintTools(try await mcp.tools())
let drift = detectToolDrift(fingerprintTools(try await mcp.tools()), baseline: approved)
if drift.hasDrift { /* drift.changed, drift.added */ }
```

## Gotchas

- A server's tools are remote code you did not write. Gate the destructive ones behind `toolApproval:` ([timeouts-and-approvals.md](timeouts-and-approvals.md)).
- MCP tool results are often large. Mark read-only ones `.idempotent()` so [compaction](context-management.md) can replace their output with a pointer.
- `MCPSSETransport` cannot retry the long-lived stream in place: on a `401` it refreshes the token and throws, so reconnect to pick up the new one.
- Anthropic's hosted MCP connector (`AnthropicModel.Tools.mcpToolset`) is a different thing: the server runs on Anthropic's side, with no local `MCPClient`. See [providers.md](providers.md).

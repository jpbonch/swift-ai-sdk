# Terminal UI — `AITUI`

The `@ai-sdk/tui` analog. Separate library product; add `.product(name: "AITUI", package: "swift-ai-sdk")` next to `AI`. macOS and Linux only (POSIX TTY).

## Entry points

```swift
@MainActor func runAgentTUI(
    title: String = "Assistant",
    agent: Agent,                       // or: transport: any ChatTransport
    tools: TerminalPartDisplayMode = .autoCollapsed,
    reasoning: TerminalPartDisplayMode = .autoCollapsed,
    responseStatistics: ResponseStatisticsMode = .outputTokensPerSecond,
    contextSize: Int? = nil,
    theme: TerminalTheme = .default
) async throws
```

Runs until the user exits. Throws `AgentTUIError.notATerminal` when stdin/stdout is not a TTY (so pipes fail loudly), `.unsupportedPlatform` off POSIX.

```swift
try await runAgentTUI(title: "Weather Agent", agent: Agent(model: model, tools: [weather]))
try await runAgentTUI(title: "Remote", transport: HTTPChatTransport(api: api))
```

`agent:` wraps the agent in `AgentChatTransport`, which is `Agent`'s `ChatTransport` conformance plus `usage` in message metadata (that is where the token statistics come from). Any `ChatTransport` works with `transport:`.

## Display modes

`TerminalPartDisplayMode`: `.full` (header + content), `.collapsed` (header only), `.autoCollapsed` (expanded only while it is the newest section — the default), `.hidden`. Applies independently to `tools:` and `reasoning:`. A tool card in `.approvalRequested` is always expanded regardless of mode.

`ResponseStatisticsMode`: `.outputTokensPerSecond` (default) or `.outputTokenCount`. `contextSize:` adds a `12.3k/200k ctx (6%)` readout. Remote transports show statistics only when the server sends `usage` in message metadata.

## Approvals

Tools with `needsApproval: true` pause the loop; the UI shows a prompt row and `y`/`n` respond. Approval mutates the `ToolUIPart` to `.approvalResponded` and resubmits, the same path as `ChatSession.addToolApprovalResponse` → `convertToModelMessages` → `.toolApprovalResponse`.

## Controls

Enter submit · `y`/`n` approve/deny · ↑↓ scroll · PageUp/PageDown page · ←→/Home/End cursor · Ctrl+W delete word · Ctrl+U clear · Ctrl+L repaint · Esc stop stream then exit · Ctrl+C exit.

## Reusable pieces (pure, no TTY needed)

- `MarkdownTerminalRenderer.render(_:width:theme:) -> [StyledLine]` — headings, lists, fenced code, quotes, rules, inline bold/italic/code/strike/links, wrapping with hanging indents.
- `TranscriptRenderer.lines(for:width:options:)` — `[UIMessage]` → styled lines with tool cards and reasoning sections.
- `AgentTUIModel` — state machine: input editing, scroll clamping, `pendingApproval`, `respondToApproval`, statistics strings.
- `AgentTUIRenderer.frame(model:size:styled:) -> AgentTUIFrame` — full screen plus cursor position.
- `StyledLine.render(styled:)` — ANSI on/off; `TerminalText.width` counts CJK/emoji as two columns.

Color is dropped when `NO_COLOR` is set or `TERM=dumb`. The app runs on the alternate screen and restores raw mode, cursor, and screen on exit.

## Not ported

`sandbox:` (the `@ai-sdk/sandbox-*` session forwarded as `experimental_sandbox`) has no Swift counterpart.

# References — router

Pick the file that matches the task. Open one or two, not all.

| File | Use for |
| --- | --- |
| [text-generation.md](text-generation.md) | `generateText` / `streamText`, prompts and messages, sampling settings, stop conditions, lifecycle callbacks (`onChunk`/`onAbort`), `smoothStream`, `output:` structured result, `providerMetadata`, sources/citations |
| [structured-output.md](structured-output.md) | `generateObject`, `generateObjectArray`, `streamObject` (+ `elementStream`), `generateEnum`, `generateJSON`, `repairText`, and the `Schema` DSL |
| [tools.md](tools.md) | Function `Tool`, typed arguments, execution context, approvals, client-side tools, provider-executed tools (`<Model>.Tools`), computer use, multimodal tool results, and `repairToolCall` |
| [agents.md](agents.md) | `Agent` (the ToolLoopAgent analog), loop control (`stopWhen`/`stepCountIs`/`hasToolCall`), `prepareCall`, `prepareStep`, `toolOrder`, subagents via `asTool` |
| [providers.md](providers.md) | The capability matrix, first-class provider models, custom compatible endpoints, keys/base URLs, `ProviderRegistry`, and `customProvider` |
| [reasoning.md](reasoning.md) | `ReasoningEffort` and how it maps to each provider's native reasoning controls; consuming `.reasoningDelta` |
| [middleware.md](middleware.md) | `wrapLanguageModel` with `cache`, `extractReasoning`, `simulateStreaming`, `defaultSettings`, and custom `wrapCall`/`transformRequest`/`wrapStream` hooks |
| [chat-ui.md](chat-ui.md) | `ChatSession`, `CompletionSession`, `ObjectSession` for SwiftUI; `ChatTransport`/`HTTPChatTransport`/`LocalChatTransport`; the UI-message stream protocol and `/api/chat` compatibility |
| [runtime-context.md](runtime-context.md) | `runtimeContext`, tool `contextSchema` and computed descriptions, dynamic tools, `uploadFile` + `providerReference`, remote-URL inlining, transport request hooks, `TelemetrySettings` |
| [timeouts-and-approvals.md](timeouts-and-approvals.md) | `GenerationTimeout` (total/step/first-chunk/chunk/tool), call-level `toolApproval` policy and decisions, HMAC-signed approvals (`toolApprovalSecret`), and `pruneMessages` |
| [context-management.md](context-management.md) | `compaction:` salience-aware auto-compaction (`Compaction`, `CompactedContext`, `CompactionBudget`, `CompactionPinning`, `CompactionEvent`), `Tool.idempotent()` pointer-izing, and `contextWindow` / `ModelContextWindows` |
| [mcp.md](mcp.md) | `MCPClient`, the HTTP / stdio / legacy-SSE transports, OAuth for hosted servers (`MCPOAuthSession`, `MCPOAuthClientProvider`, `MCPOAuthFlow`, the RFC 9728 → RFC 8414 discovery chain), and tool-drift detection |
| [terminal-ui.md](terminal-ui.md) | `runAgentTUI` (`AITUI`): interactive terminal chat over an `Agent` or `ChatTransport`, display modes for tools/reasoning, response statistics and context size, `y`/`n` tool approvals, and the standalone renderers (`TranscriptRenderer`, `MarkdownTerminalRenderer`) |
| [realtime.md](realtime.md) | `RealtimeSession` and the realtime models (OpenAI, Google Gemini Live, xAI) for live voice |
| [media.md](media.md) | `generateImage` (`maxImagesPerCall`), `generateSpeech`, `transcribe`, `generateVideo` and their provider packs (incl. BFL, ByteDance, Kling, Prodia, QuiverAI, Cartesia, xAI, Alibaba) |
| [on-device.md](on-device.md) | `FoundationModelsModel` — Apple Intelligence with a cloud fallback |
| [embeddings.md](embeddings.md) | `embed`, `embedMany`, `cosineSimilarity`, `rerank` (Cohere, Voyage), and the embedding packs |
| [testing.md](testing.md) | The `AITesting` module, mock models, and `simulateReadableStream` |
| [errors.md](errors.md) | `AIError` cases and handling patterns |

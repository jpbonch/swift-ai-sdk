# Runtime context, tool context, dynamic tools, and attachments

## `runtimeContext:`

`JSONValue?` on `generateText` / `streamText` / `Agent`. Shared server-side state for a run (tenant, request id, budget) that never enters the prompt.

- Read in `prepareStep` via `PrepareStepContext.runtimeContext` (which also carries `toolsContext`).
- Replace for later steps by returning `PrepareStepResult(runtimeContext:)`.
- Recorded on every `StepResult.runtimeContext`.
- Not passed to tools — per-tool state belongs in `toolsContext`.

## Tool context

`toolsContext: [String: JSONValue]` keys per tool name; each tool sees only its entry as `ToolExecutionOptions.context`.

```swift
Tool(...)
    .withContextSchema(Schema.object(["apiKey": .string()]))   // validated before execute
    .describing { context in "Weather in \(context?["unit"]?.stringValue ?? "celsius")" }
```

Invalid context fails that call with `AIError.invalidToolContext(tool:reason:)`; the tool never runs. Computed descriptions are resolved per step, so the model sees the context-specific text.

## Dynamic tools

`Tool.dynamic(name:description:parameters:execute:)` for runtime-determined schemas. Sets `isDynamic`, which flows to `ToolCall.isDynamic` and the `dynamic` field on `tool-input-available` / `tool-output-available` / `tool-output-error` chunks. `MCPTool` is dynamic automatically.

## Attachments

```swift
let uploaded = try await uploadFile(api: OpenAIFiles(), data: pdf, filename: "r.pdf",
                                    mediaType: "application/pdf")
.file(mediaType:) / .image(mediaType:)   // -> FileContent / ImageContent with providerReference
```

`FileUploadAPI` is the protocol (`OpenAIFiles`, `AnthropicFiles` conform). `providerReference` is `[providerName: fileID]`; OpenAI sends `file_id` on `input_file`/`input_image`, Anthropic a `{"type": "file", "file_id": …}` source. Other providers ignore references not minted for them.

## Remote URLs

`LanguageModel.supportsRemoteURL(_:mediaType:)` defaults to `true`; `BedrockModel` returns `false`. The loop calls `RemoteContent.inlineUnsupportedURLs` before each step, downloading and inlining what the model cannot fetch. http(s) only (a `file://` URL throws), 32 MB cap, `data:` URLs and provider references untouched.

## Transport hooks

`HTTPChatTransport(prepareSendMessagesRequest:prepareReconnectToStreamRequest:)` return `PreparedChatRequest(api:headers:body:)`; their headers/body win over the static ones. Use for refreshed tokens, trimmed history, or a different resume URL.

## Telemetry

`TelemetrySettings(isEnabled:functionID:metadata:includeRuntimeContext:includeToolsContext:)`. Context keys reach spans only when named; `.disabled` skips span emission for one call.

## Helpers and errors

`filterActiveTools(_:activeTools:)`, `generateId(size:)`, `createIdGenerator(prefix:separator:alphabet:size:)`, `GeneratedFile` (`base64`, `bytes`) with `file`/`files` on `GenerateImageResult`.

New `AIError` cases: `invalidToolInput`, `invalidToolContext`, `missingToolResults`, `toolCallRepairFailed`, `invalidToolApproval`, `unsupportedFunctionality`.

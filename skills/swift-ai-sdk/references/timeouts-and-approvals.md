# Timeouts, approval policy, and history pruning

## Timeouts — `GenerationTimeout`

`timeout:` on `generateText` / `streamText` / `Agent`.

```swift
GenerationTimeout(
    total: Duration?,        // whole call, all steps -> AIError.timedOut(scope: .total)
    step: Duration?,         // one model call (stream lifetime)
    firstChunk: Duration?,   // until first content of a step (streaming)
    chunk: Duration?,        // between content chunks after output starts
    tool: Duration?,         // default tool execution limit
    tools: [String: Duration] // per-tool override, wins over `tool`
)
GenerationTimeout.after(.seconds(30))   // == total
```

Content-bearing (satisfies/resets stall timers): non-empty `textDelta`, `reasoningDelta`, `toolArgumentsDelta`, plus `toolCall`, `toolResult`, `source`. Not content: `toolCallStart`, `providerMetadata`, `finish`, empty deltas.

Tool timeouts become an error `ToolResult` (the model can retry); every other scope throws `AIError.timedOut(scope:limit:tool:)`. `.watchesStream` / `.isEmpty` / `.limit(forTool:)` are the helpers.

## Approval policy — `toolApproval:`

Call-level, four decisions, each with an optional reason:

```swift
public enum ToolApprovalDecision { case notApplicable, approved(reason:), denied(reason:), userApproval(reason:) }
```

- `.notApplicable` → run normally, and fall back to the tool's own `needsApproval`.
- `.approved` → run, recorded in `step.approvalDecisions[toolCallID]`.
- `.denied` → skip; the model gets a `ToolResult(denied: true)` with the reason and keeps going.
- `.userApproval` → emit `ToolApprovalRequest`, pause the loop (`finishReason == .toolCalls`).

Three construction forms:

```swift
toolApproval: ["deleteFile": .userApproval()]                       // dictionary literal
toolApproval: .perTool(["weather": { ctx in ... }])                 // closure per tool
toolApproval: ToolApprovalPolicy { ctx in ... }                      // one closure for all
```

`ToolApprovalContext` carries `toolCall`, `tool`, `messages`, `stepNumber`, `steps` — enough for history-aware rules (counts, running totals, "second destructive action"). `PrepareCallResult(toolApproval:)` supplies it per call.

## Signed approvals — `toolApprovalSecret:`

HMAC-SHA256 over an injective JSON payload `["ai.tool-approval.v1", approvalID, toolName, toolCallID, input]`. Signature rides `ToolApprovalRequest.signature` → `tool-approval-request` chunk → `ToolApproval.signature` on the UI part → back on `ToolApprovalResponse.signature`. `ChatSession.addToolApprovalResponse` and `AgentTUIModel.respondToApproval` preserve it.

Verification is fail-closed: with a secret set, a missing/invalid/tampered signature yields a denied result and the tool never runs. No secret → unchanged behavior. `ToolApprovalSignature.sign/verify` are public for custom transports.

## Pruning — `pruneMessages`

```swift
pruneMessages(messages, toolCalls: .beforeLastMessages(6, tools: ["search"]), emptyMessages: .remove)
pruneMessages(uiMessages, reasoning: .beforeLastMessage, toolCalls: .all)
```

`PruneScope`: `.all`, `.beforeLastMessage`, `.beforeLastMessages(n)`, `.none`. Dropping a tool call also drops its result and approval response. Reasoning pruning is only on the `[UIMessage]` overload — `Message` has no reasoning parts in this port.

Pruning is lossy: it deletes. When the goal, the decisions, or the failed approaches have to survive, use `compaction:` instead ([context-management.md](context-management.md)).

## Related additions

- Middleware: `.extractJson()`, `.addToolInputExamples(prefix:)` (+ `Tool(inputExamples:)`), `wrapEmbeddingModel`, `wrapImageModel`, `wrapProvider`.
- `streamTranscribe` + `StreamingTranscriptionModel` (Deepgram live). `.partialTranscript` replaces, `.transcriptDelta` appends.
- `TextStreamChatTransport`, `consumeStream`, `validateUIMessages`, `lastAssistantMessageIsCompleteWithToolCalls` / `lastAssistantMessageIsCompleteWithApprovalResponses`, `resampleAudio`.

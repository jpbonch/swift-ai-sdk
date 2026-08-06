# Context management: compaction and context windows

Two ways to keep a long run inside the window. `pruneMessages` **deletes** (lossy, free, in [timeouts-and-approvals.md](timeouts-and-approvals.md)). `compaction:` **preserves the substance** at the cost of one model call. Reach for compaction when losing the goal, the decisions, or the failed approaches would hurt.

## `compaction:` is automatic and salience-aware

On `generateText` / `streamText` / `Agent`. Triggers itself when history outgrows the working-set budget.

```swift
Compaction(
    budget: CompactionBudget = .init(),   // fractions of the context window
    pinning: CompactionPinning = .default,
    keepLastSteps: Int = 4,
    onCompact: (@Sendable (CompactionEvent) -> Void)? = nil
)
```

**Organizing rule: compress in proportion to how cheaply the information can be recovered.** Bulk tool output is re-fetchable, so compress it hard. A decision's rationale exists only in the transcript, so keep it.

Three layers, in order; the first two make no model call:

1. **Structural pinning.** System messages, the first user message (the goal), and any message carrying a failed tool result are lifted out of the compressible span. `keepLastSteps` messages stay verbatim as the working set.
2. **Live-reference scan.** An older message sharing an identifier (file path, symbol, id) with the working set is live and gets pinned. The thing being actively worked on survives without a model deciding.
3. **Typed extraction.** One `generateObject` call over what remains, using the run's own model, yielding a `CompactedContext` rendered into a single replacement message.

`CompactionPinning` is an `OptionSet`: `.firstUserMessage`, `.errors`, `.liveReferences`; `.default` is all three.

Re-entrant: the previous `CompactedContext` feeds the next extraction, so a long run converges rather than growing.

## `CompactedContext` is a schema, not a prose summary

`goal`, `decisions`, and `deadEnds` are **required** schema fields, so extraction cannot silently drop them. That is the whole point: a freeform "summarize this" can lose the goal and you would never know.

```swift
struct CompactedContext: Codable, Sendable, Hashable {
    var goal: String                 // required, never compressed away
    var constraints: [String]
    var decisions: [Decision]        // .what + .why
    var establishedFacts: [Fact]     // .claim + .source (the tool that found it)
    var deadEnds: [DeadEnd]          // .approach + .failure
    var openQuestions: [String]
    var artifacts: [Artifact]        // .reference + .summary + .producedBy, pointers not contents
}
```

Dead ends are the entry most summarizers drop and the costliest loss: an agent that forgets a failed approach retries it. `ContextCompactor.render(_:)` produces the text form (goal first, then only the non-empty sections).

## Idempotent tools gate pointer-izing

A tool result is replaced by a pointer **only** when its tool is marked idempotent:

```swift
Tool(name: "read_file", description: "…", parameters: schema) { … }.idempotent()
```

→ `[omitted: read_file returned ~4200 characters — re-run the tool to retrieve it]`

The tool **call** is kept verbatim even then, because it records what was already tried. `isIdempotent` is `false` by default on `AIToolProtocol`, so anything with side effects (payments, sends) keeps its full output.

## `CompactionBudget` takes fractions, not a threshold

```swift
CompactionBudget(contextWindow: Int? = nil, workingSet: Double = 0.5, compacted: Double = 0.2)
```

`contextWindow: nil` means "ask the model", so one config is correct across tiers: an Opus run gets a 500K working set, a Haiku run 100K. Resolution helpers: `contextWindow(for:)`, `workingSetTokens(for:)`, `compactedTokens(for:)` (plus `…(window:)` variants).

Token estimate is `characters / 4` (`ContextCompactor.estimateTokens`), fine for a trigger but it drifts on code and non-English text.

## `CompactionEvent`, what `onCompact` receives

`messagesBefore` / `messagesAfter`, `estimatedTokensBefore` / `estimatedTokensAfter`, `context: CompactedContext`, `pointerizedTools: [String]`.

## `contextWindow` on `LanguageModel`

```swift
var contextWindow: Int { get }   // default impl resolves from the model id
AnthropicModel("claude-opus-5").contextWindow   // 1_000_000
XaiModel("grok-4").contextWindow                // 256_000
```

The protocol extension default means every provider pack reports a window with no per-provider wiring. `ModelContextWindows.resolve(provider:modelID:)` matches a normalized id (dots to dashes, substring match, so `claude-haiku-4-5-20251001` and `gemini-2.5-pro` both hit).

Unknown ids get `ModelContextWindows.conservativeDefault` (128K), deliberately below the common 200K. Under-estimating compacts early; over-estimating overflows the window and fails the request. Don't "fix" it upward.

```swift
ModelContextWindows.register(64_000, for: "my-finetune")   // beats the built-in table
```

Anthropic entries come from current Anthropic docs. Gemini, Grok, and o-series are best-known values; the GPT family is deliberately absent and falls back to 128K rather than guess. Override or add table rows to tighten.

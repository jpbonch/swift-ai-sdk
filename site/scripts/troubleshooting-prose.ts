// Troubleshooting pages, one per symptom.
//
// Named after what someone would actually search or paste, not after the tidy
// internal concept. Each entry states the symptom, why it happens, and the fix.
//
// Edit here, then `pnpm api:reference` to regenerate.

import type { Group } from './api-types';

/** One troubleshooting page, keyed by its slug. */
export type TroubleshootingEntry = {
  group: string;
  title: string;
  summary: string;
  symptom: string;
  cause: string;
  fix: string;
  seeAlso?: [label: string, href: string][];
};

export const groups: Group[] = [
  { slug: 'tools', title: 'Tools' },
  { slug: 'output', title: 'Output' },
  { slug: 'limits', title: 'Limits and timeouts' },
  { slug: 'providers', title: 'Providers and auth' },
  { slug: 'streaming', title: 'Streaming and UI' },
];

export const prose: Record<string, TroubleshootingEntry> = {
  'missing-tool-results': {
    group: 'tools',
    title: 'AIError.missingToolResults',
    summary: 'A conversation was sent on with tool calls that have no matching results.',
    symptom: `A call throws \`AIError.missingToolResults([...])\`, listing one or more tool
call ids.`,
    cause: `Every \`toolCall\` in an assistant message needs a matching \`toolResult\` before
that conversation can go back to the model. The array in the error is the ids
that are unanswered.

This nearly always happens in a client-side tool flow: the model asked for a
tool, the app was supposed to run it and post the result back, and the next
turn started before that happened. It also happens after pruning a history by
hand and dropping a result while keeping its call.`,
    fix: `Check the history is complete before resuming:

\`\`\`swift
if lastAssistantMessageIsCompleteWithToolCalls(messages) {
  try await resume(messages)
}
\`\`\`

If you prune histories yourself, use
[\`pruneMessages\`](/docs/reference/prune-messages) rather than filtering by
hand. Dropping a tool call there also drops its result, so the pair can never
get split.`,
    seeAlso: [
      ['Tools', '/docs/tools'],
      ['pruneMessages', '/docs/reference/prune-messages'],
    ],
  },

  'unknown-tool': {
    group: 'tools',
    title: 'AIError.unknownTool',
    summary: 'The model called a tool that was not in the tools array.',
    symptom: `\`AIError.unknownTool("some_name")\` thrown mid-loop.`,
    cause: `The model asked for a tool the call does not know about. Two common routes:

The tool array changed between turns while the history still refers to the old
one. The model sees a prior turn where \`search\` existed, and asks for it again
on a call where it was not passed.

Or \`activeTools\` narrowed the set. A tool filtered out of \`activeTools\` is
hidden from the model, but a model working from history may still ask.`,
    fix: `Keep the tool array stable for the life of a conversation. When you do need to
vary it per step, do it in \`prepareStep\` so the change is visible to the loop
rather than applied behind it.

If the tool genuinely no longer exists, prune the history so the model stops
seeing evidence of it.`,
    seeAlso: [
      ['Tools', '/docs/tools'],
      ['filterActiveTools', '/docs/reference/filter-active-tools'],
    ],
  },

  'invalid-tool-input': {
    group: 'tools',
    title: 'AIError.invalidToolInput',
    summary: 'Tool arguments failed schema validation, so the tool never ran.',
    symptom: `\`AIError.invalidToolInput(tool:reason:)\`. The tool's own code never executed.`,
    cause: `Arguments are validated against the tool's schema before the executor is
called, so a malformed call fails closed rather than reaching your code with
missing fields.

Smaller models get this wrong more often, especially with deeply nested schemas
or unusual enum values.`,
    fix: `Supply \`repairToolCall\` to fix a call and retry it instead of failing the run:

\`\`\`swift
repairToolCall: { call, tools in
  guard call.name == "search" else { return nil }
  var fixed = call
  fixed.arguments = normalize(call.arguments)
  return fixed
}
\`\`\`

Flattening the schema helps more than prompting does. So does adding
\`inputExamples\` to the tool, which Anthropic sends natively and other providers
can receive through the \`.addToolInputExamples()\` middleware.`,
    seeAlso: [
      ['Tools', '/docs/tools'],
      ['Errors', '/docs/reference/errors'],
    ],
  },

  'invalid-tool-approval': {
    group: 'tools',
    title: 'AIError.invalidToolApproval',
    summary: 'An approval response failed verification.',
    symptom: `\`AIError.invalidToolApproval(...)\` when resuming after an approval.`,
    cause: `When \`toolApprovalSecret\` is set, approvals are HMAC-signed and verified
fail-closed. The check rejects a response whose signature does not match, one
that was replayed, or one for a tool that was never offered.

In practice this is usually benign: the secret changed between the request and
the response, or a client dropped the \`signature\` field while round-tripping
the message.`,
    fix: `Make sure the same \`toolApprovalSecret\` is used for the call that requested the
approval and the call that resumes it, and that your client preserves the
signature verbatim rather than reconstructing the approval object.

\`ChatSession\` and the terminal UI carry signatures back automatically. If you
wrote your own transport, that is the first place to look.`,
    seeAlso: [['Timeouts and approvals', '/docs/timeouts-and-approvals']],
  },

  'tool-never-executes': {
    group: 'tools',
    title: 'A tool is offered but never runs',
    summary: 'The model calls a tool and the loop stops instead of executing it.',
    symptom: `The result comes back with a \`toolCall\` in \`toolCalls\` but no matching entry in
\`toolResults\`, and the loop ended.`,
    cause: `The tool has no executor. A \`Tool\` built without an \`execute\` closure is a
client-side tool by design: the SDK surfaces the call and expects your app to
run it and post the result back. \`hasExecutor\` is \`false\` for these.

Provider-defined tools behave the same way from the loop's side, since they run
on the provider rather than locally.`,
    fix: `If the tool was meant to run locally, give it an \`execute\` closure. If it is
genuinely client-side, handle the call in your UI and send a result back before
resuming, then check with
[\`lastAssistantMessageIsCompleteWithToolCalls\`](/docs/reference/last-assistant-message-is-complete-with-tool-calls).`,
    seeAlso: [['Tools', '/docs/tools']],
  },

  'no-object-generated': {
    group: 'output',
    title: 'AIError.noObjectGenerated',
    summary: 'Structured output did not parse or validate.',
    symptom: `\`AIError.noObjectGenerated(...)\` from \`generateObject\`, \`generateObjectArray\`,
or \`streamObject\`.`,
    cause: `The model's output was not valid JSON, or it was valid JSON that did not
satisfy the schema.

The most common cause is not the model at all: the response hit
\`maxOutputTokens\` and got cut off. A truncated object is invalid JSON, and the
error looks identical to a model that simply got it wrong.`,
    fix: `Raise \`maxOutputTokens\` first. It fixes this more often than any prompt change,
and costs nothing when the output is short anyway.

If the output is complete but malformed, pass \`repairText\` to salvage it:

\`\`\`swift
repairText: { text in
  text.trimmingCharacters(in: CharacterSet(charactersIn: "\` \\n"))
}
\`\`\`

For models that wrap JSON in markdown fences even when asked not to, the
\`.extractJson()\` middleware strips them.`,
    seeAlso: [
      ['Structured output', '/docs/structured-output'],
      ['generateObject', '/docs/reference/generate-object'],
    ],
  },

  'decoding-error': {
    group: 'output',
    title: 'AIError.decoding',
    summary: 'A response arrived but did not match the expected shape.',
    symptom: `\`AIError.decoding(...)\` on an otherwise successful request.`,
    cause: `The HTTP call succeeded and the body did not look like what the provider's API
documents.

Usually one of: the provider returned an error document with a 200, or the
endpoint is "OpenAI-compatible" but diverges on a field the SDK reads. Local
servers and gateways are the usual suspects.`,
    fix: `Log the raw body. If it is an error document, the real problem is in the
message it carries.

If it is a genuine shape difference, the OpenAI-compatible base accepts
\`headers:\` and \`queryParams:\` overrides that often bridge the gap. For a
persistent mismatch, wrap the model and normalize the response in middleware.`,
    seeAlso: [
      ['OpenAI-compatible providers', '/docs/providers/openai-compatible'],
      ['Middleware', '/docs/middleware'],
    ],
  },

  'context-window-exceeded': {
    group: 'limits',
    title: 'Running out of context on a long run',
    summary: 'A long agent loop fails or degrades once the history outgrows the window.',
    symptom: `An HTTP 400 from the provider mentioning tokens or context length, or a run
that quietly gets worse the longer it goes.`,
    cause: `Every tool result stays in the history. A loop that reads files or searches
accumulates context fast, and the biggest entries are usually tool output that
is no longer relevant.`,
    fix: `Turn on compaction. It triggers itself when the history outgrows the working-set
budget and keeps the goal, the decisions, and the failed approaches while
compressing bulk tool output:

\`\`\`swift
compaction: Compaction()
\`\`\`

Mark read-only tools \`.idempotent()\` so their output can be replaced by a
pointer the model can re-fetch. For a cheap structural fix with no model call,
[\`pruneMessages\`](/docs/reference/prune-messages) deletes old tool traffic
outright.

If the budget looks wrong for your model, check \`contextWindow\` resolves: an
unrecognized model id falls back to a conservative 128K.`,
    seeAlso: [
      ['Context management', '/docs/context-management'],
      ['pruneMessages', '/docs/reference/prune-messages'],
    ],
  },

  'timed-out': {
    group: 'limits',
    title: 'AIError.timedOut',
    summary: 'A timeout fired. The scope tells you which one and what to change.',
    symptom: `\`AIError.timedOut(scope:limit:tool:)\`.`,
    cause: `Read \`scope\` before changing anything, because each one means something
different:

\`.total\` is the whole call including every step. \`.step\` is one model call.
\`.firstChunk\` means a stream produced nothing at all within the limit.
\`.chunk\` means a stream started and then stalled. A populated \`tool\` means one
specific tool ran long.

Stall timers only count content-bearing output, so provider keep-alive metadata
cannot hold a dead stream open.`,
    fix: `Raise the scope that actually fired rather than the total. An agent loop that
trips \`.total\` usually needs more steps allowed, not a longer clock.

Tool timeouts do not throw by default. They come back as a tool error the model
can read and react to, which is normally what you want:

\`\`\`swift
timeout: GenerationTimeout(total: .seconds(600), tool: .seconds(30))
\`\`\``,
    seeAlso: [['Timeouts and approvals', '/docs/timeouts-and-approvals']],
  },

  'http-401-unauthorized': {
    group: 'providers',
    title: 'HTTP 401 from a provider',
    summary: 'The API key is missing, wrong, or not reaching the provider.',
    symptom: `\`AIError.http(status: 401, body: ...)\`.`,
    cause: `Every provider pack falls back to a conventional environment variable when
\`apiKey:\` is omitted, and an unset variable resolves to an empty string rather
than crashing. So a missing key looks exactly like a wrong one, and only fails
at request time.

A GUI-launched app is the classic case: it does not inherit the environment
your shell exports, so the key is present in Terminal and absent in the app.`,
    fix: `Pass the key explicitly when the process environment is not reliable:

\`\`\`swift
AnthropicModel("claude-sonnet-5", apiKey: storedKey)
\`\`\`

Check the body in the error too. Providers usually say whether the key is
unknown, revoked, or lacking access to the specific model.`,
    seeAlso: [['Providers', '/docs/providers']],
  },

  'ollama-connection-refused': {
    group: 'providers',
    title: 'Cannot reach a local model server',
    summary: 'Ollama or another local server is not running, or is on a different port.',
    symptom: `\`AIError.transport(...)\` mentioning a refused connection to \`localhost:11434\`.`,
    cause: `\`OllamaModel\` defaults to \`http://localhost:11434/v1\`. The server is not
running, is bound elsewhere, or the model was never pulled.`,
    fix: `Start the server and pull a model:

\`\`\`bash
ollama serve
ollama pull qwen3
\`\`\`

For a non-default host, pass \`baseURL:\` explicitly. Note that a model Ollama has
not pulled fails at request time, not at construction, so a typo in the model id
looks like a server problem.`,
    seeAlso: [['Ollama', '/docs/providers/ollama']],
  },

  'mcp-authorization-required': {
    group: 'providers',
    title: 'AIError.authorizationRequired from an MCP server',
    summary: 'A hosted MCP server needs an OAuth sign-in that could not be refreshed.',
    symptom: `\`AIError.authorizationRequired(url:)\` when listing or calling MCP tools.`,
    cause: `The server returned a 401 and the session had no token, or had one it could not
refresh. The URL in the error is the sign-in page.

This is the normal first-run path for a hosted server, not necessarily a
failure.`,
    fix: `Open the URL, then hand the redirect back:

\`\`\`swift
let tokens = try await auth.complete(callbackURL: redirect)
\`\`\`

If it recurs on every run, your \`MCPOAuthClientProvider\` is not persisting
tokens and client registration. Both need to survive a relaunch.

If sign-in itself fails, the usual cause is \`saveState\` / \`state\` left as the
no-op defaults, which makes callback verification silently pass and then fail
later.`,
    seeAlso: [['MCP', '/docs/mcp']],
  },

  'on-device-model-unavailable': {
    group: 'providers',
    title: 'Apple on-device model is unavailable',
    summary: 'Foundation Models is not ready on this machine.',
    symptom: `A run reports the on-device model as unavailable, with an availability reason.`,
    cause: `Apple Intelligence has to be enabled and its assets downloaded before
\`FoundationModelsModel\` can serve requests. Availability is a device and OS
state, not something the SDK controls.`,
    fix: `Check before constructing, and fall back to a cloud model when it is not ready:

\`\`\`swift
let model: any LanguageModel = FoundationModelsModel.isAvailable
  ? FoundationModelsModel()
  : AnthropicModel("claude-sonnet-5")
\`\`\`

\`FoundationModelsModel.availability\` carries the reason, which is worth
surfacing rather than swallowing. Foundation Models also reports no token
usage, so statistics readouts stay empty on that path.`,
    seeAlso: [['On-device models', '/docs/on-device']],
  },

  'stream-ends-early': {
    group: 'streaming',
    title: 'A stream stops before the answer finishes',
    summary: 'Output is cut off mid-sentence with no error.',
    symptom: `Streamed text stops partway and the run reports success.`,
    cause: `Check \`finishReason\` first. \`.length\` means the response hit
\`maxOutputTokens\` and stopped there, which is not an error as far as the API is
concerned.

Reasoning models make this more likely, because thinking tokens count toward
the same budget as the answer.`,
    fix: `Raise \`maxOutputTokens\`. The SDK default is deliberately small, and reasoning
models need real headroom.

If \`finishReason\` is \`.stop\` and the text still looks truncated, the model
genuinely ended there and the fix is in the prompt.`,
    seeAlso: [
      ['Generating text', '/docs/generating-text'],
      ['streamText', '/docs/reference/stream-text'],
    ],
  },

  'duplicate-tool-parts-in-ui': {
    group: 'streaming',
    title: 'Tool parts overwrite each other in the UI',
    summary: 'A repeated tool call id collapses two calls into one card.',
    symptom: `Two separate tool calls render as one, or a finished tool card is replaced by a
running one.`,
    cause: `The UI-message reducer keys tool parts by call id. When a provider reuses an
id across calls, or a transport replays one, the second call lands on the first
one's part.

The SDK starts a new UI tool part when it sees a reused id rather than
overwriting the finished one, so if you are still seeing collapsing the ids are
being rewritten somewhere in your own transport.`,
    fix: `Check that your transport passes tool call ids through unchanged. If you mint
ids yourself, use [\`generateId\`](/docs/reference/generate-id) or
[\`createIdGenerator\`](/docs/reference/create-id-generator) so they match
the format the loop produces and stay unique.`,
    seeAlso: [
      ['Chat UI', '/docs/chat-ui'],
      ['Streaming protocol', '/docs/streaming-protocol'],
    ],
  },
};

// Hand-written prose for the type reference pages, one entry per type.
//
// Members (properties, initializers, methods, cases) are NOT here — those come
// from lib/api-index.json, generated from Sources/AI. Everything in this file
// is written by hand: what the type is for, when you'd reach for it, and a
// minimal example.
//
// Only types people construct or inspect directly get a page. The index holds
// all 271 public types; most of them are plumbing nobody needs to look up.
//
// Edit prose here, then `pnpm api:reference` to regenerate the .mdx pages.

import type { Group } from './api-types';

export type TypeProse = {
  group: string;
  summary: string;
  body: string;
  example: string;
  seeAlso?: [label: string, href: string][];
};

export const typeGroups: Group[] = [
  { slug: 'building-blocks', title: 'Building blocks' },
  { slug: 'results', title: 'Results' },
  { slug: 'configuration', title: 'Configuration' },
  { slug: 'ui', title: 'UI' },
  { slug: 'values', title: 'Values' },
];

export const typeProse: Record<string, TypeProse> = {
  // -------------------------------------------------------- building blocks ---
  Agent: {
    group: 'building-blocks',
    summary: 'A model, its instructions, and its tools bundled into one reusable object.',
    body: `Everything you would otherwise pass to [\`generateText\`](/docs/reference/generate-text)
on every call, held in one value you configure once and call many times. The
properties mirror that function's parameters exactly, so anything you can do
there you can do here.

Reach for it when the same setup runs more than once: a support agent, a code
reviewer, a research step in a larger pipeline. For a single one-off call, the
free functions are less ceremony.

An agent can also become a tool for another agent via \`asTool\`, which is how
you build a supervisor that delegates to specialists.`,
    example: `let researcher = Agent(
  model: AnthropicModel("claude-sonnet-5"),
  instructions: "You research questions and cite your sources.",
  tools: [webSearch]
)

let result = try await researcher.generate(prompt: "Who first isolated neon?")`,
    seeAlso: [
      ['Agents guide', '/docs/agents'],
      ['generateText', '/docs/reference/generate-text'],
      ['Tool', '/docs/reference/tool'],
    ],
  },

  Tool: {
    group: 'building-blocks',
    summary: 'A function the model can call, with a name, a description, and a parameter schema.',
    body: `A tool is a name, a description, a schema for its arguments, and a closure
that runs when the model calls it. The description isn't decoration. It's the
only thing the model reads when deciding whether this tool applies, so it's
worth as much care as the code.

The loop in \`generateText\` and \`streamText\` executes tools for you and feeds
their results back to the model. You only write the closure.

Modifiers on a tool change how the loop treats it. \`.idempotent()\` marks a
tool as safe to call again with the same arguments, which lets compaction drop
its result knowing it can be recovered.`,
    example: `let weather = Tool(
  name: "get_weather",
  description: "Current conditions for a city.",
  parameters: .object(["city": .string(description: "City name")])
) { args, _ in
  let city = args["city"]?.stringValue ?? "London"
  return .string(try await fetchWeather(city))
}.idempotent()`,
    seeAlso: [
      ['Tools guide', '/docs/tools'],
      ['Agent', '/docs/reference/agent'],
      ['ToolChoice', '/docs/reference/tool-choice'],
    ],
  },

  Message: {
    group: 'building-blocks',
    summary: 'One turn in a conversation: a role and the content parts that make it up.',
    body: `A role plus an array of [\`ContentPart\`](/docs/reference/content-part). Text is
the common case, but a single message can also carry images, files, tool calls,
tool results, and reasoning.

Messages are what you pass when a call needs history rather than a bare prompt.
Building them by hand is normal; the convenience initializers cover the simple
text case so you rarely spell out the parts.

Order matters and so does completeness: every tool call in an assistant message
needs a matching tool result before that conversation can go back to the model.`,
    example: `let messages: [Message] = [
  .system("Answer in one sentence."),
  .user("What is the tallest mountain?"),
  .assistant("Mount Everest, at 8,849 metres."),
  .user("And the second?")
]`,
    seeAlso: [
      ['Messages guide', '/docs/messages'],
      ['ContentPart', '/docs/reference/content-part'],
      ['convertToModelMessages', '/docs/reference/convert-to-model-messages'],
    ],
  },

  ContentPart: {
    group: 'building-blocks',
    summary: 'One piece of a message: text, an image, a file, a tool call, a result, or reasoning.',
    body: `Messages are arrays of these. Splitting a turn into parts is what lets one
message hold a sentence and an image, or an assistant turn hold both its
reasoning and the tool calls it decided on.

You mostly construct the text and image cases and read the rest. Tool calls and
tool results are produced by the loop, and reasoning parts appear only for
models that expose their thinking.`,
    example: `let message = Message(
  role: .user,
  content: [
    .text("What is in this photo?"),
    .image(data: photoData, mediaType: "image/jpeg")
  ]
)`,
    seeAlso: [
      ['Messages guide', '/docs/messages'],
      ['Message', '/docs/reference/message'],
    ],
  },

  // ---------------------------------------------------------------- results ---
  GenerateTextResult: {
    group: 'results',
    summary: 'Everything one finished generateText call produced.',
    body: `The finished text is on \`text\`, but the result carries the whole run: every
step the loop took, the tool calls and results within them, token usage, the
reason generation stopped, and the provider's raw response.

Reach past \`text\` when you need to audit what happened: which tools ran, how
many steps it took, whether it stopped because the model finished or because it
hit a limit.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: "Summarise this in one line.",
  tools: [search]
)

print(result.text)
print("\\(result.steps.count) steps, \\(result.usage.totalTokens) tokens")`,
    seeAlso: [
      ['generateText', '/docs/reference/generate-text'],
      ['StreamTextResult', '/docs/reference/stream-text-result'],
    ],
  },

  StreamTextResult: {
    group: 'results',
    summary: 'A live stream of one generation, plus the finished result once it lands.',
    body: `What \`streamText\` hands back before the model has finished. Iterate it to
consume parts as they arrive, whether those are text deltas, tool calls, tool
results, or reasoning. Or await the finished result if you decide mid-flight
that you want the whole thing after all.

The stream is single-pass. If you need both the live parts and the final
result, consume the stream and read the result afterwards rather than trying to
iterate twice.`,
    example: `let stream = streamText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: "Write a haiku about deadlines."
)

for try await delta in stream.textStream {
  print(delta, terminator: "")
}`,
    seeAlso: [
      ['streamText', '/docs/reference/stream-text'],
      ['GenerateTextResult', '/docs/reference/generate-text-result'],
    ],
  },

  // ---------------------------------------------------------- configuration ---
  Compaction: {
    group: 'configuration',
    summary: 'Automatic context compaction: when to compress a conversation, and how hard.',
    body: `Long conversations eventually outgrow the model's context window. Compaction
watches the token count and, past a threshold, replaces the older turns with a
structured summary so the run can keep going.

It compresses in proportion to how cheaply something can be recovered. A tool
result you can fetch again is worth less than a decision you can't re-derive.
And a dead end, meaning something already tried that didn't work, is the most
valuable thing to keep and the first thing a naive summariser throws away.

Pass it to \`generateText\`, \`streamText\`, or an \`Agent\` and it runs itself.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  messages: history,
  tools: tools,
  compaction: Compaction()
)`,
    seeAlso: [
      ['Context management', '/docs/context-management'],
      ['CompactedContext', '/docs/reference/compacted-context'],
      ['pruneMessages', '/docs/reference/prune-messages'],
    ],
  },

  CompactedContext: {
    group: 'configuration',
    summary: 'The structured summary compaction produces: goal, decisions, dead ends, and facts.',
    body: `What compaction extracts from the turns it compresses, and what gets rendered
back into the conversation in their place.

The shape is deliberate. Free-form summaries lose exactly the things that are
expensive to rediscover, so this pins them into named fields: what the run is
trying to do, what has been decided, what has been established, and what has
already been tried and failed.

You rarely build one by hand. Read it when you want to see what compaction kept
and what it let go.`,
    example: `let compaction = Compaction(
  onCompact: { event in
    print("kept \\(event.context.decisions.count) decisions")
    print("dropped \\(event.messagesCompacted) messages")
  }
)`,
    seeAlso: [
      ['Context management', '/docs/context-management'],
      ['Compaction', '/docs/reference/compaction'],
    ],
  },

  GenerationTimeout: {
    group: 'configuration',
    summary: 'Deadlines for a generation: total wall clock, and how long a silent stream may stall.',
    body: `Two different failures need two different limits. A call that runs too long
overall is one problem; a stream that opens fine and then goes quiet is
another, and a total timeout catches the second one far too late.

So this carries both: a ceiling on the whole call, and a ceiling on the gap
between chunks. Either one firing cancels the request.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  timeout: GenerationTimeout(total: .seconds(60), stall: .seconds(10))
)`,
    seeAlso: [
      ['Timeouts and approvals', '/docs/timeouts-and-approvals'],
      ['Timed out', '/docs/troubleshooting/timed-out'],
    ],
  },

  ToolApprovalPolicy: {
    group: 'configuration',
    summary: 'Which tool calls need a human yes before they run.',
    body: `Some tools shouldn't fire on the model's say-so alone. Anything that spends
money, sends a message, or deletes something. A policy sits between the model
asking and the tool running, and pauses the loop until you approve.

You can require approval for everything, for nothing, or for a named set. The
loop surfaces the pending call, waits, and resumes with your answer.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  tools: [search, sendEmail],
  toolApproval: .requiring(["send_email"])
)`,
    seeAlso: [
      ['Timeouts and approvals', '/docs/timeouts-and-approvals'],
      ['Approvals guide', '/docs/guides/approvals'],
    ],
  },

  StopCondition: {
    group: 'configuration',
    summary: 'When the tool loop should stop taking another step.',
    body: `By default the loop runs until the model stops asking for tools or hits
\`maxSteps\`. A stop condition lets you end it on your own terms: after a
particular tool has been called, once a step count is reached, or on any
predicate you write over the steps so far.

Conditions compose. Pass several and the loop stops when any one is met.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  tools: [search, finish],
  stopWhen: [hasToolCall("finish"), stepCountIs(10)]
)`,
    seeAlso: [
      ['Agents guide', '/docs/agents'],
      ['stepCountIs', '/docs/reference/step-count-is'],
      ['hasToolCall', '/docs/reference/has-tool-call'],
    ],
  },

  ToolChoice: {
    group: 'configuration',
    summary: 'Whether the model may call tools, must call one, or must call a specific one.',
    body: `\`.auto\` lets the model decide, which is what you want almost always. The
other cases are for the moments when you need to take that decision away:
forcing a tool call on the first step, or forbidding tools while the model
writes its final answer.

Forcing a specific tool is a useful trick for structured extraction. Give the
model one tool whose schema is the shape you want back.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  tools: [extractInvoice],
  toolChoice: .tool("extract_invoice")
)`,
    seeAlso: [
      ['Tools guide', '/docs/tools'],
      ['Tool', '/docs/reference/tool'],
    ],
  },

  TelemetrySettings: {
    group: 'configuration',
    summary: 'What the SDK records about a run, and where it sends it.',
    body: `Turns on tracing for a call: spans for each step, tool execution, and model
request, with token counts attached. Off by default, because recording prompts
and completions is a decision about user data, not a default.

Enable it per call or per agent. Recording of prompt and completion text is a
separate switch from recording the spans themselves.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  telemetry: TelemetrySettings(isEnabled: true, functionID: "summarise")
)`,
    seeAlso: [['Telemetry', '/docs/telemetry']],
  },

  // --------------------------------------------------------------------- ui ---
  ChatSession: {
    group: 'ui',
    summary: 'An observable chat you can bind a SwiftUI view to.',
    body: `Holds the message list, the in-flight status, and the send/stop/regenerate
actions behind an observable object, so a view can bind to it and stay in sync
without you writing the plumbing.

It handles the parts that are tedious to get right by hand: streaming deltas
into the right message, keeping tool call and result parts paired, surfacing
errors, and cancelling cleanly when someone hits stop.`,
    example: `@State private var chat = ChatSession(
  model: AnthropicModel("claude-sonnet-5")
)

var body: some View {
  MessageList(messages: chat.messages)
  TextField("Message", text: $draft)
    .onSubmit { Task { await chat.send(draft) } }
}`,
    seeAlso: [
      ['Chat UI', '/docs/chat-ui'],
      ['Chat screen guide', '/docs/guides/chat-screen'],
    ],
  },

  // ----------------------------------------------------------------- values ---
  JSONValue: {
    group: 'values',
    summary: 'A JSON value: object, array, string, number, boolean, or null.',
    body: `The SDK's currency for anything whose shape isn't known at compile time:
tool arguments, tool results, provider options, runtime context.

It is an enum rather than \`Any\`, so it stays \`Sendable\` and its cases are
exhaustive. Accessors like \`stringValue\` unwrap the common cases without a
switch, and it is \`ExpressibleBy\` the usual literals, so writing one by hand
reads close to writing JSON.`,
    example: `let options: JSONValue = [
  "thinking": ["type": "enabled", "budget_tokens": 2048]
]

let city = args["city"]?.stringValue ?? "London"`,
    seeAlso: [
      ['Structured output', '/docs/structured-output'],
      ['Runtime context', '/docs/runtime-context'],
    ],
  },

  MCPClient: {
    group: 'values',
    summary: 'A connection to an MCP server, and the tools it exposes.',
    body: `Connects to a Model Context Protocol server over stdio, streamable HTTP, or
the legacy SSE transport, and turns the tools it advertises into tools your
model can call.

The tools it returns are ordinary [\`Tool\`](/docs/reference/tool) values, so
they mix freely with ones you wrote yourself. Servers that require OAuth are
handled by attaching a session; the client refreshes and retries on a 401
rather than making you catch it.`,
    example: `let client = try await MCPClient(
  transport: .streamableHTTP(url: URL(string: "https://mcp.example.com")!)
)

let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: prompt,
  tools: try await client.tools()
)`,
    seeAlso: [
      ['MCP', '/docs/mcp'],
      ['Authorization required', '/docs/troubleshooting/mcp-authorization-required'],
    ],
  },
};

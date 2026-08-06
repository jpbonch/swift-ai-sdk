// Hand-written prose for every reference page, one entry per public function.
//
// Signatures, parameters, and overloads are NOT here — those come from
// lib/api-index.json, generated from Sources/AI. Everything in this file is
// written by hand: what the function does, when to reach for it, a minimal
// example, and what comes back.
//
// Edit prose here, then `pnpm api:reference` to regenerate the .mdx pages.

import type { Group } from './api-types';

/** One reference page's hand-written half. */
export type ReferenceEntry = {
  group: string;
  summary: string;
  body: string;
  example: string;
  returns: string;
  seeAlso?: [label: string, href: string][];
};

export const groups: Group[] = [
  { slug: 'text', title: 'Text' },
  { slug: 'structured', title: 'Structured output' },
  { slug: 'embeddings', title: 'Embeddings and ranking' },
  { slug: 'media', title: 'Images, audio, and video' },
  { slug: 'loop', title: 'Loop control' },
  { slug: 'context', title: 'Context' },
  { slug: 'middleware', title: 'Middleware and providers' },
  { slug: 'ui', title: 'UI and transports' },
  { slug: 'mcp', title: 'MCP' },
  { slug: 'audio', title: 'Audio buffers' },
  { slug: 'utility', title: 'Utilities' },
];

export const prose: Record<string, ReferenceEntry> = {
  // ---------------------------------------------------------------- text ---
  generateText: {
    group: 'text',
    summary: 'Generate text and run the tool loop to completion, returning one finished result.',
    body: `Runs a model to completion and returns the whole result at once. If you pass
tools, it drives the full loop (call the model, execute the tools it asks for,
feed the results back) until a stop condition is met.

Reach for it when nothing is watching the output arrive: a background job, a
server route that returns JSON, a summarizer, an agent step. When a person is
watching the text appear, use [\`streamText\`](/docs/reference/stream-text)
instead.`,
    example: `let result = try await generateText(
  model: AnthropicModel("claude-sonnet-5"),
  prompt: "Invent a holiday and describe its traditions."
)
print(result.text)`,
    returns: `\`GenerateTextResult\` carries the finished \`text\`, plus \`reasoningText\`,
\`toolCalls\`, \`toolResults\`, \`sources\`, \`steps\`, \`messages\`,
\`providerMetadata\`, \`experimentalOutput\`, \`finishReason\`, and \`usage\`.

\`steps\` is the per-iteration record of the tool loop, so \`result.stepCount\`
tells you how many model calls it took. \`messages\` is the conversation
including everything the loop appended, ready to pass into the next turn.`,
    seeAlso: [
      ['Generating text', '/docs/generating-text'],
      ['streamText', '/docs/reference/stream-text'],
      ['generateObject', '/docs/reference/generate-object'],
      ['Timeouts and approvals', '/docs/timeouts-and-approvals'],
    ],
  },

  streamText: {
    group: 'text',
    summary: 'Stream text, reasoning, tool calls, and results as they arrive.',
    body: `The streaming counterpart to \`generateText\`, with the same tool loop and the
same parameters. Instead of waiting for a finished result you consume an
\`AsyncSequence\` of parts as the model produces them.

Use it anywhere a person is waiting on output. The stream carries more than
text: reasoning deltas, tool call starts, tool results, sources, and provider
metadata all arrive in order, so a UI can show the model working rather than a
spinner.`,
    example: `let stream = streamText(
  model: OpenAIModel("gpt-5.1"),
  prompt: "Write a haiku about Swift concurrency."
)

for try await text in stream.textStream {
  print(text, terminator: "")
}`,
    returns: `\`StreamTextResult\` exposes several views of the same run. \`textStream\` yields
only text deltas; \`fullStream\` yields every \`TextStreamPart\` including
reasoning, tool activity, and metadata. Awaiting \`text\`, \`steps\`, \`usage\`, or
\`finishReason\` gives you the finished values once the stream completes.`,
    seeAlso: [
      ['Generating text', '/docs/generating-text'],
      ['generateText', '/docs/reference/generate-text'],
      ['smoothStream', '/docs/reference/smooth-stream'],
      ['Chat UI', '/docs/chat-ui'],
    ],
  },

  streamTextDeltas: {
    group: 'text',
    summary: 'A minimal text-only stream, without the tool loop.',
    body: `Streams raw text deltas straight from a model with no tool loop, no steps, and
no result accumulation. It is the smallest possible streaming call.

Use it when you want tokens and nothing else, or when you are building your own
loop on top of the model protocol. Most applications want
[\`streamText\`](/docs/reference/stream-text).`,
    example: `for try await delta in streamTextDeltas(
  model: OllamaModel("qwen3"),
  prompt: "Count to ten."
) {
  print(delta, terminator: "")
}`,
    returns: `An \`AsyncThrowingStream<String, Error>\` of text deltas.`,
    seeAlso: [['streamText', '/docs/reference/stream-text']],
  },

  // ---------------------------------------------------------- structured ---
  generateObject: {
    group: 'structured',
    summary: 'Generate a typed value validated against a JSON schema.',
    body: `Constrains the model to a JSON schema and decodes the response into a
\`Decodable\` type. Validation happens before decoding, so a response that does
not fit the schema throws rather than producing a half-populated value.

This is the call for extraction, classification, and any time you need the
model's answer as data rather than prose. Pass \`JSONValue.self\` when you want
the raw object instead of a Swift type.`,
    example: `struct Recipe: Decodable, Sendable {
  let title: String
  let ingredients: [String]
}

let result = try await generateObject(
  model: AnthropicModel("claude-sonnet-5"),
  of: Recipe.self,
  schema: Schema.object([
    "title": .string(),
    "ingredients": .array(of: .string())
  ]).jsonSchema,
  prompt: "A recipe for lasagna."
)
print(result.object.title)`,
    returns: `\`GenerateObjectResult<T>\` with the decoded \`object\`, the \`rawJSON\` it came
from, \`finishReason\`, and \`usage\`.`,
    seeAlso: [
      ['Structured output', '/docs/structured-output'],
      ['generateObjectArray', '/docs/reference/generate-object-array'],
      ['streamObject', '/docs/reference/stream-object'],
    ],
  },

  generateObjectArray: {
    group: 'structured',
    summary: 'Generate a typed array, validating each element against a schema.',
    body: `Like [\`generateObject\`](/docs/reference/generate-object), but the schema
describes one element and the result is an array of them.

Use it for list extraction where the element shape is known and the count is
not: pulling every line item off an invoice, every attendee out of an email.`,
    example: `let result = try await generateObjectArray(
  model: OpenAIModel("gpt-5.1"),
  of: Attendee.self,
  elementSchema: Schema.object([
    "name": .string(), "email": .string()
  ]).jsonSchema,
  prompt: email
)`,
    returns: `\`GenerateObjectResult<[T]>\`, with the array in \`object\`.`,
    seeAlso: [
      ['Structured output', '/docs/structured-output'],
      ['generateObject', '/docs/reference/generate-object'],
    ],
  },

  streamObject: {
    group: 'structured',
    summary: 'Stream a structured object as its fields fill in.',
    body: `Streams partial versions of a structured result while the model is still
generating it, so a UI can render fields as they land instead of waiting for
the closing brace.

For array schemas, \`elementStream\` yields each complete element as it
finishes, which is usually what you want for a list that renders row by row.`,
    example: `let stream = streamObject(
  model: AnthropicModel("claude-sonnet-5"),
  schema: schema,
  prompt: "Three startup ideas."
)

for try await partial in stream.partialObjectStream {
  render(partial)
}`,
    returns: `\`StreamObjectResult\` with \`partialObjectStream\`, \`elementStream\` for array
schemas, and awaitable \`object\`, \`usage\`, and \`finishReason\`.`,
    seeAlso: [
      ['Structured output', '/docs/structured-output'],
      ['generateObject', '/docs/reference/generate-object'],
    ],
  },

  generateEnum: {
    group: 'structured',
    summary: 'Pick exactly one value from a fixed set.',
    body: `Constrains the model to choose one of the strings you supply. The result is
guaranteed to be a member of the set, so classification never needs a
post-check or a fuzzy match.

Cheaper and more reliable than asking for a label in prose and parsing it.`,
    example: `let result = try await generateEnum(
  model: AnthropicModel("claude-haiku-4-5-20251001"),
  values: ["billing", "technical", "sales"],
  prompt: ticket
)
print(result.value)`,
    returns: `\`GenerateEnumResult\` with the chosen \`value\`, \`finishReason\`, and \`usage\`.`,
    seeAlso: [['Structured output', '/docs/structured-output']],
  },

  generateJSON: {
    group: 'structured',
    summary: 'Generate free-form JSON with no schema.',
    body: `Asks for valid JSON without constraining its shape, returning a \`JSONValue\`.

Use it when the shape genuinely is not known ahead of time. When you do know
it, [\`generateObject\`](/docs/reference/generate-object) is better in every
way: it validates, it decodes, and the model follows a schema more reliably
than an instruction.`,
    example: `let result = try await generateJSON(
  model: OpenAIModel("gpt-5.1"),
  prompt: "Summarize this log as JSON."
)
print(result.object["level"]?.stringValue ?? "")`,
    returns: `\`GenerateObjectResult<JSONValue>\`.`,
    seeAlso: [['generateObject', '/docs/reference/generate-object']],
  },

  // ---------------------------------------------------------- embeddings ---
  embed: {
    group: 'embeddings',
    summary: 'Embed a single string into a vector.',
    body: `Turns one string into a vector for similarity search, clustering, or
classification. For more than one value use
[\`embedMany\`](/docs/reference/embed-many), which batches.`,
    example: `let result = try await embed(
  model: OpenAIEmbeddingModel("text-embedding-3-small"),
  value: "swift concurrency"
)
print(result.embedding.count)`,
    returns: `\`EmbedResult\` with the \`embedding\` vector and \`usage\`.`,
    seeAlso: [
      ['Embeddings', '/docs/embeddings'],
      ['embedMany', '/docs/reference/embed-many'],
      ['cosineSimilarity', '/docs/reference/cosine-similarity'],
    ],
  },

  embedMany: {
    group: 'embeddings',
    summary: 'Embed many strings, batching automatically.',
    body: `Embeds an array of strings, splitting into batches when the list exceeds what
the provider accepts in one request. Order is preserved, so the vector at index
\`i\` belongs to the value at index \`i\`.

Set \`maxBatchSize\` to stay under a provider's limit or to ease off a rate
limit.`,
    example: `let result = try await embedMany(
  model: OpenAIEmbeddingModel("text-embedding-3-small"),
  values: documents
)`,
    returns: `\`EmbedManyResult\` with \`embeddings\` in input order and combined \`usage\`.`,
    seeAlso: [
      ['Embeddings', '/docs/embeddings'],
      ['embed', '/docs/reference/embed'],
    ],
  },

  cosineSimilarity: {
    group: 'embeddings',
    summary: 'Cosine similarity between two vectors.',
    body: `Pure arithmetic, no network call. Returns a value from -1 to 1, where 1 means
the vectors point the same way.

Vectors of different lengths, or a zero vector, return 0 rather than throwing.`,
    example: `let score = cosineSimilarity(queryVector, documentVector)`,
    returns: `A \`Double\` between -1 and 1.`,
    seeAlso: [['Embeddings', '/docs/embeddings']],
  },

  rerank: {
    group: 'embeddings',
    summary: 'Reorder candidate documents against a query.',
    body: `Sends a query and a list of documents to a reranking model, which scores how
well each one answers the query. More accurate than embedding similarity
because the model sees the query and document together.

The usual shape is retrieve broadly with embeddings, then rerank the top
candidates before handing them to a model.`,
    example: `let result = try await rerank(
  model: CohereRerankingModel("rerank-v3.5"),
  query: "how do I cancel a subscription",
  documents: candidates,
  topN: 5
)`,
    returns: `\`RerankResult\` with scored, ordered \`results\` and \`usage\`.`,
    seeAlso: [['Reranking', '/docs/reranking']],
  },

  // --------------------------------------------------------------- media ---
  generateImage: {
    group: 'media',
    summary: 'Generate or edit images.',
    body: `Generates images from a prompt, or edits an existing one when you pass image
data. \`n\` asks for several at once; when it exceeds what the provider allows
per call, the request is split into batches automatically.`,
    example: `let result = try await generateImage(
  model: OpenAIImageModel("gpt-image-2"),
  prompt: "A red bicycle against a white wall",
  size: "1024x1024"
)
let png = result.images[0].bytes`,
    returns: `\`GenerateImageResult\` with \`images\` as \`GeneratedFile\` values, exposing
\`base64\` and \`bytes\`, plus \`providerMetadata\`.`,
    seeAlso: [['Image generation', '/docs/image-generation']],
  },

  detectImageMediaType: {
    group: 'media',
    summary: "Read an image's media type from its magic bytes.",
    body: `Sniffs the first twelve bytes of image data and returns the media type it
finds: PNG, JPEG, GIF, WebP, HEIC, or BMP. Nothing else is inspected, so the
answer is only as good as the header.

\`generateImage\` already uses this to label results a provider returns without
a media type. Reach for it directly when you have raw bytes from somewhere else
— a file on disk, a download, a pasteboard — and need to tag them before
sending them to a model.`,
    example: `let mediaType = detectImageMediaType(bytes) ?? "image/png"`,
    returns: `The media type as a \`String\`, or \`nil\` when the header matches none of
the recognized formats or the data is shorter than twelve bytes.`,
    seeAlso: [['Image generation', '/docs/image-generation']],
  },

  generateSpeech: {
    group: 'media',
    summary: 'Synthesize speech from text.',
    body: `Turns text into audio using a speech model. \`voice\`, \`speed\`, and
\`outputFormat\` are passed through to the provider when it supports them.`,
    example: `let result = try await generateSpeech(
  model: OpenAISpeechModel("gpt-4o-mini-tts"),
  text: "Your order has shipped.",
  voice: "alloy"
)`,
    returns: `\`GenerateSpeechResult\` with the \`audio\` file and \`providerMetadata\`.`,
    seeAlso: [['Speech generation', '/docs/speech-generation']],
  },

  generateVideo: {
    group: 'media',
    summary: 'Generate video, polling until the job completes.',
    body: `Video generation is asynchronous at every provider. This call submits the job
and polls until it finishes, so you await one result instead of managing the
job yourself.

Expect it to take minutes. Give the surrounding call a generous timeout.`,
    example: `let result = try await generateVideo(
  model: XaiVideoModel("grok-video"),
  prompt: "A timelapse of clouds over a city"
)`,
    returns: `\`GenerateVideoResult\` with the \`video\` file and \`providerMetadata\`.`,
    seeAlso: [['Video generation', '/docs/video-generation']],
  },

  transcribe: {
    group: 'media',
    summary: 'Transcribe an audio file to text.',
    body: `Transcribes recorded audio. When the declared media type is generic, the
format is sniffed from the bytes themselves, so MP4, M4A, WAV, Ogg, FLAC, and
MP3 are recognized without you naming them.

For microphone input that should transcribe as it arrives, use
[\`streamTranscribe\`](/docs/reference/stream-transcribe).`,
    example: `let result = try await transcribe(
  model: DeepgramTranscriptionModel("nova-3"),
  audio: try Data(contentsOf: url)
)
print(result.text)`,
    returns: `\`TranscriptionResult\` with \`text\`, \`segments\`, detected \`language\`,
\`durationInSeconds\`, and \`providerMetadata\`.`,
    seeAlso: [
      ['Transcription', '/docs/transcription'],
      ['streamTranscribe', '/docs/reference/stream-transcribe'],
    ],
  },

  streamTranscribe: {
    group: 'media',
    summary: 'Transcribe live audio as it arrives.',
    body: `Streams audio to a transcription model over a WebSocket and yields text as it
is recognized.

Interim guesses arrive as \`.partialTranscript\`, which **replaces** the current
partial, while settled text arrives as \`.transcriptDelta\`, which **appends**.
Keeping those separate is what stops revisions from double-counting.`,
    example: `for try await part in streamTranscribe(
  model: DeepgramTranscriptionModel("nova-3"),
  audio: micStream
) {
  switch part {
  case .partialTranscript(let text): showInterim(text)
  case .transcriptDelta(let text): append(text)
  default: break
  }
}`,
    returns: `A \`StreamTranscriptionResult\` whose stream yields \`TranscriptionStreamPart\`
values, plus an awaitable final \`result\`.`,
    seeAlso: [
      ['Transcription', '/docs/transcription'],
      ['transcribe', '/docs/reference/transcribe'],
    ],
  },

  detectAudioMediaType: {
    group: 'media',
    summary: 'Identify an audio format from its bytes.',
    body: `Sniffs the container from the leading bytes and returns a media type. Used
internally by [\`transcribe\`](/docs/reference/transcribe) when the declared
type is generic; exposed because it is useful on its own.`,
    example: `let mediaType = detectAudioMediaType(data)  // "audio/mp4", "audio/wav", ...`,
    returns: `A media type \`String\`, or \`nil\` when nothing matches.`,
    seeAlso: [['transcribe', '/docs/reference/transcribe']],
  },

  // ---------------------------------------------------------------- loop ---
  stepCountIs: {
    group: 'loop',
    summary: 'Stop the tool loop after a number of steps.',
    body: `The stop condition you will use most. Caps how many times the loop may call
the model, which bounds both cost and the chance of an agent spinning.`,
    example: `stopWhen: [stepCountIs(5)]`,
    returns: `A \`StopCondition\`.`,
    seeAlso: [
      ['Agents', '/docs/agents'],
      ['hasToolCall', '/docs/reference/has-tool-call'],
    ],
  },

  isStepCount: {
    group: 'loop',
    summary: 'Stop on an exact step number.',
    body: `Fires when the loop reaches exactly this step, where
[\`stepCountIs\`](/docs/reference/step-count-is) fires at or past it. Use it
when you are composing conditions and need equality rather than a ceiling.`,
    example: `stopWhen: [isStepCount(3)]`,
    returns: `A \`StopCondition\`.`,
    seeAlso: [['stepCountIs', '/docs/reference/step-count-is']],
  },

  hasToolCall: {
    group: 'loop',
    summary: 'Stop once a named tool has been called.',
    body: `Ends the loop as soon as the model calls the tool you name. The usual pattern
is a terminal tool such as \`submit_answer\` or \`finish\`, which turns "the model
decided it is done" into a stop condition.`,
    example: `stopWhen: [hasToolCall("submit_answer")]`,
    returns: `A \`StopCondition\`.`,
    seeAlso: [['Agents', '/docs/agents']],
  },

  isLoopFinished: {
    group: 'loop',
    summary: 'Stop when the model stops asking for tools.',
    body: `Fires on the first step where the model returns no tool calls, which is the
loop's natural end. Rarely needed explicitly, since the loop already stops
there; useful when composing it with other conditions.`,
    example: `stopWhen: [isLoopFinished()]`,
    returns: `A \`StopCondition\`.`,
    seeAlso: [['Agents', '/docs/agents']],
  },

  // ------------------------------------------------------------- context ---
  pruneMessages: {
    group: 'context',
    summary: 'Drop old tool traffic and reasoning from a history.',
    body: `A pure function that deletes old tool calls, tool results, and (for
\`UIMessage\` histories) reasoning from a conversation. No model call, no cost.

Pruning is lossy by design. When the goal, the decisions, or the failed
approaches need to survive, use \`compaction:\` instead, which summarizes rather
than deletes.`,
    example: `let trimmed = pruneMessages(
  messages,
  toolCalls: .beforeLastMessages(6, tools: ["search"])
)`,
    returns: `A new array of the same type, with the pruned entries removed. Dropping a
tool call also drops its result and any approval response.`,
    seeAlso: [
      ['Context management', '/docs/context-management'],
      ['filterActiveTools', '/docs/reference/filter-active-tools'],
    ],
  },

  filterActiveTools: {
    group: 'context',
    summary: 'Narrow a tool list to a named subset.',
    body: `Returns only the tools whose names appear in the list you pass, preserving
order. Handy inside \`prepareStep\` to change which tools a model can see from
one step to the next without rebuilding the array.`,
    example: `filterActiveTools(tools, names: ["search", "read_file"])`,
    returns: `A filtered \`[any AIToolProtocol]\`.`,
    seeAlso: [['Tools', '/docs/tools']],
  },

  // ---------------------------------------------------------- middleware ---
  wrapLanguageModel: {
    group: 'middleware',
    summary: 'Wrap a language model with middleware.',
    body: `Returns a model that behaves like the one you passed in, with middleware
intercepting requests and stream parts. Middlewares apply in array order.

Built-ins cover caching, reasoning extraction, default settings, simulated
streaming, JSON fence stripping, and folding tool input examples into
descriptions.`,
    example: `let model = wrapLanguageModel(
  model: OllamaModel("qwen3"),
  middleware: [.cache(), .extractReasoning(tag: "think")]
)`,
    returns: `An \`any LanguageModel\` you can use anywhere the original worked.`,
    seeAlso: [['Middleware', '/docs/middleware']],
  },

  wrapEmbeddingModel: {
    group: 'middleware',
    summary: 'Wrap an embedding model with middleware.',
    body: `The embedding-model counterpart to
[\`wrapLanguageModel\`](/docs/reference/wrap-language-model), using
\`EmbeddingModelMiddleware\`.`,
    example: `let embeddings = wrapEmbeddingModel(
  model: OpenAIEmbeddingModel("text-embedding-3-small"),
  middleware: [.defaultSettings(maxBatchSize: 96)]
)`,
    returns: `An \`any EmbeddingModel\`.`,
    seeAlso: [['Middleware', '/docs/middleware']],
  },

  wrapImageModel: {
    group: 'middleware',
    summary: 'Wrap an image model with middleware.',
    body: `The image-model counterpart to
[\`wrapLanguageModel\`](/docs/reference/wrap-language-model). Commonly used
to append house style to every prompt.`,
    example: `let images = wrapImageModel(
  model: OpenAIImageModel("gpt-image-2"),
  middleware: [ImageModelMiddleware(transformRequest: { request in
    var request = request
    request.prompt += ", studio lighting"
    return request
  })]
)`,
    returns: `An \`any ImageModel\`.`,
    seeAlso: [['Middleware', '/docs/middleware']],
  },

  wrapProvider: {
    group: 'middleware',
    summary: 'Wrap every model a provider produces.',
    body: `Applies middleware at the provider level, so every model the provider hands
out is already wrapped. Saves repeating the same wrapping at each call site.`,
    example: `let provider = wrapProvider(
  provider: myProvider,
  languageModelMiddleware: [.cache()]
)`,
    returns: `A \`WrappedProvider\`.`,
    seeAlso: [['Middleware', '/docs/middleware']],
  },

  customProvider: {
    group: 'middleware',
    summary: 'Build a provider from your own model lookups.',
    body: `Assembles a provider out of closures that resolve a model id to a model, with
an optional fallback. Use it to alias ids, pin defaults, or route
\`"provider:model"\` strings at your own boundary.`,
    example: `let provider = customProvider(
  languageModels: ["fast": OpenAIModel("gpt-5.1-mini")],
  fallbackProvider: nil
)`,
    returns: `A \`ProviderRegistry.Provider\`.`,
    seeAlso: [['Providers', '/docs/providers']],
  },

  // ------------------------------------------------------------------ ui ---
  readUIMessageStream: {
    group: 'ui',
    summary: 'Turn a UI message stream into message snapshots.',
    body: `Consumes the UI-message wire protocol and yields a growing \`UIMessage\` after
each chunk, so a view can render the latest snapshot without reducing chunks
itself.`,
    example: `for try await message in readUIMessageStream(stream: chunks) {
  render(message)
}`,
    returns: `An \`AsyncThrowingStream<UIMessage, Error>\`.`,
    seeAlso: [['Streaming protocol', '/docs/streaming-protocol']],
  },

  convertToModelMessages: {
    group: 'ui',
    summary: 'Convert UI messages to model messages.',
    body: `Maps the \`UIMessage\` shape a client sends into the \`Message\` values a model
takes, flattening UI-only parts. This is the first thing a server route does
with an incoming chat body.`,
    example: `let messages = convertToModelMessages(body.messages)`,
    returns: `A \`[Message]\`.`,
    seeAlso: [['Streaming protocol', '/docs/streaming-protocol']],
  },

  consumeStream: {
    group: 'ui',
    summary: 'Drain a stream to completion, discarding output.',
    body: `Runs a stream to the end without collecting it. Use it when the work matters
but the output does not, such as making sure \`onFinish\` fires and the run is
persisted even if the client disconnected.`,
    example: `try await consumeStream(stream: result.fullStream)`,
    returns: `Nothing.`,
    seeAlso: [['Chat UI', '/docs/chat-ui']],
  },

  validateUIMessages: {
    group: 'ui',
    summary: 'Validate incoming UI messages, throwing on bad input.',
    body: `Checks that messages from a client are well formed before you hand them to a
model. Throws on the first problem.

For a non-throwing check, use
[\`safeValidateUIMessages\`](/docs/reference/safe-validate-ui-messages).`,
    example: `let messages = try validateUIMessages(body.messages)`,
    returns: `The validated \`[UIMessage]\`.`,
    seeAlso: [['Chat UI', '/docs/chat-ui']],
  },

  safeValidateUIMessages: {
    group: 'ui',
    summary: 'Validate UI messages without throwing.',
    body: `The non-throwing form of
[\`validateUIMessages\`](/docs/reference/validate-ui-messages), returning a
result you can branch on. Use it at a request boundary where you would rather
return a 400 than surface an error.`,
    example: `switch safeValidateUIMessages(body.messages) {
case .success(let messages): try await handle(messages)
case .failure(let error): return .badRequest(error)
}`,
    returns: `A \`UIMessageValidation\` describing success or the failure.`,
    seeAlso: [['Chat UI', '/docs/chat-ui']],
  },

  lastAssistantMessageIsCompleteWithToolCalls: {
    group: 'ui',
    summary: 'Check whether the last assistant turn has all its tool results.',
    body: `Returns true when the final assistant message's tool calls all have matching
results, meaning the turn is ready to continue. Used to decide whether to
resume a loop after a client round trip.`,
    example: `if lastAssistantMessageIsCompleteWithToolCalls(messages) {
  try await resume(messages)
}`,
    returns: `A \`Bool\`.`,
    seeAlso: [['Chat UI', '/docs/chat-ui']],
  },

  lastAssistantMessageIsCompleteWithApprovalResponses: {
    group: 'ui',
    summary: 'Check whether pending tool approvals have been answered.',
    body: `The approval counterpart to
[\`lastAssistantMessageIsCompleteWithToolCalls\`](/docs/reference/last-assistant-message-is-complete-with-tool-calls):
true once every approval request in the last turn has a response, so the run
can continue.`,
    example: `if lastAssistantMessageIsCompleteWithApprovalResponses(messages) {
  try await resume(messages)
}`,
    returns: `A \`Bool\`.`,
    seeAlso: [['Timeouts and approvals', '/docs/timeouts-and-approvals']],
  },

  smoothStream: {
    group: 'ui',
    summary: 'Re-chunk a text stream by word or line.',
    body: `Providers emit deltas at whatever granularity they like, which can look jittery
in a UI. This re-chunks the stream by word or line and paces it, so text
appears at a steady rhythm.

Cosmetic only. It changes when text is delivered, never what it says.`,
    example: `let smoothed = smoothStream(stream: result.textStream, chunking: .word)`,
    returns: `An \`AsyncThrowingStream<String, Error>\`.`,
    seeAlso: [['Chat UI', '/docs/chat-ui']],
  },

  // ----------------------------------------------------------------- mcp ---
  fingerprintTools: {
    group: 'mcp',
    summary: 'Snapshot tool definitions so changes can be detected.',
    body: `Hashes each tool's name, description, and schema into a fingerprint you can
store. Pair it with
[\`detectToolDrift\`](/docs/reference/detect-tool-drift) to notice when a
remote server changes a tool after a user approved it.`,
    example: `let approved = fingerprintTools(try await mcp.tools())`,
    returns: `A \`[String: MCPToolFingerprint]\` keyed by tool name.`,
    seeAlso: [['MCP', '/docs/mcp']],
  },

  detectToolDrift: {
    group: 'mcp',
    summary: 'Compare tool fingerprints against an approved baseline.',
    body: `Reports which tools were added or changed since the baseline. A server that
quietly rewrites a tool's description or schema after approval is the rug-pull
attack this exists to catch.`,
    example: `let drift = detectToolDrift(fingerprintTools(latest), baseline: approved)
if drift.hasDrift { requireReapproval(drift.changed, drift.added) }`,
    returns: `An \`MCPToolDrift\` with \`added\`, \`changed\`, and \`hasDrift\`.`,
    seeAlso: [['MCP', '/docs/mcp']],
  },

  // --------------------------------------------------------------- audio ---
  resampleAudio: {
    group: 'audio',
    summary: 'Resample PCM audio between sample rates.',
    body: `Converts linear PCM from one sample rate to another, which realtime sessions
need when a microphone's rate does not match what the provider expects.`,
    example: `let resampled = resampleAudio(samples, from: 48_000, to: 24_000)`,
    returns: `The resampled samples.`,
    seeAlso: [['Realtime voice', '/docs/realtime']],
  },

  encodePCM16: {
    group: 'audio',
    summary: 'Encode samples as 16-bit PCM.',
    body: `Packs float samples into little-endian 16-bit PCM, the format realtime
providers accept.`,
    example: `let data = encodePCM16(samples)`,
    returns: `\`Data\` of 16-bit little-endian PCM.`,
    seeAlso: [['Realtime voice', '/docs/realtime']],
  },

  decodePCM16: {
    group: 'audio',
    summary: 'Decode 16-bit PCM into samples.',
    body: `The inverse of [\`encodePCM16\`](/docs/reference/encode-pcm16), for audio
arriving from a provider that you want to play or process.`,
    example: `let samples = decodePCM16(data)`,
    returns: `An array of samples.`,
    seeAlso: [['Realtime voice', '/docs/realtime']],
  },

  // ------------------------------------------------------------- utility ---
  generateId: {
    group: 'utility',
    summary: 'Generate an id in the SDK default format.',
    body: `Produces the same id format the SDK uses internally for messages and tool
calls. Use it so ids you mint by hand match the ones the loop generates.`,
    example: `let id = generateId()`,
    returns: `A \`String\`.`,
    seeAlso: [['createIdGenerator', '/docs/reference/create-id-generator']],
  },

  createIdGenerator: {
    group: 'utility',
    summary: 'Build an id generator with a prefix and alphabet.',
    body: `Returns a generator producing ids with the prefix, alphabet, size, and
separator you choose. Useful when ids need to be recognizable per surface, like
\`msg_\` and \`call_\`.`,
    example: `let nextID = createIdGenerator(prefix: "msg", size: 16)
let id = nextID()`,
    returns: `A \`@Sendable () -> String\`.`,
    seeAlso: [['generateId', '/docs/reference/generate-id']],
  },

  uploadFile: {
    group: 'utility',
    summary: 'Upload a file to a provider and get a reference back.',
    body: `Uploads bytes through any \`FileUploadAPI\` (OpenAI Files, Anthropic Files) and
returns a handle you can attach to a message. The resulting
\`providerReference\` reaches OpenAI as \`file_id\` and Anthropic as a \`file\`
source, and is ignored by providers it was not minted for.`,
    example: `let file = try await uploadFile(
  api: OpenAIFiles(),
  data: pdf,
  filename: "report.pdf"
)`,
    returns: `An \`UploadedFile\`.`,
    seeAlso: [['Files and skills', '/docs/files-and-skills']],
  },

  getRealtimeToolDefinitions: {
    group: 'utility',
    summary: 'Convert tools into realtime session definitions.',
    body: `Maps ordinary SDK tools into the shape a realtime voice session expects, so
one tool array can serve both a text loop and a voice session.`,
    example: `let definitions = getRealtimeToolDefinitions(tools)`,
    returns: `Realtime tool definitions for the session configuration.`,
    seeAlso: [['Realtime voice', '/docs/realtime']],
  },
};

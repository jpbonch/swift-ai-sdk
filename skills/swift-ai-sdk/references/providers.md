# Providers

Every provider is a `LanguageModel` (or `EmbeddingModel` / `SpeechModel` / `TranscriptionModel` / `RerankingModel`). Construct a pack, pass it to `generateText` / `streamText` / `generateObject` / `embed`. All packs read their key from an env var when `apiKey:` is omitted, and expose `baseURL:`, `headers:`, and `urlSession:` overrides. `import AI`.

Every language model also reports `contextWindow`, resolved from the model id by a protocol-extension default. See [context-management.md](context-management.md) for the catalog, the 128K fallback for unknown ids, and `ModelContextWindows.register(_:for:)`.

## Capability matrix (language models)

| Provider | Tools | Structured output | Reasoning | Vision | Sources | Cached tokens |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| OpenAI (Responses) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| OpenAI (chat) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Azure OpenAI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Anthropic | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| Google / Vertex | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Bedrock | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| xAI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Groq | ✓* | ✓* | ✓ | ✓* | — | ✓ |
| DeepSeek | ✓* | ✓* | ✓ | ✓* | — | ✓ |
| Mistral | ✓* | ✓* | ✓ | ✓* | — | — |
| Perplexity | — | ✓* | — | ✓* | ✓ | — |
| Cohere | ✓ | ✓ | — | ✓ | ✓ | — |
| Foundation Models | ✓ | ✓ | — | — | — | — |
| OpenAI-compatible | ✓* | ✓* | ✓* | ✓* | — | — |

`*` rides the shared chat-completions wire; honored only if the model supports it. Sources surface as `StreamPart.source` / `TextStreamPart.source`. Cached tokens populate `usage.cachedInputTokens` on prompt-cache hits.

Model ids are free strings — anything the provider's API serves works. The ids below are illustrative.

## Native packs

Each ctor is `init(_ modelID: String, apiKey: String? = nil, baseURL:..., headers: [String:String] = [:], urlSession: URLSession = .shared)` unless noted. `apiKey: nil` falls back to the env var.

### OpenAI — `OpenAIModel` (Responses API by default) / `.chat` (Chat Completions)

Env `OPENAI_API_KEY`, base `https://api.openai.com/v1`.

```swift
let m = OpenAIModel("gpt-5.1")
let chat = OpenAIModel.chat("gpt-4o")
```

`init(_:apiKey:baseURL:organization:project:multiAgent:headers:urlSession:)` — `baseURL` is `URL?` (nil → default). `organization` / `project` become headers. `.chat(_:...)` is a static returning an `OpenAIModel` backed by the Chat Completions engine (`OpenAIChatModel`). Reasoning ruleset applies to `o1*`, `o3*`, `o4-mini*`, `gpt-5*` except `gpt-5-chat*`; `gpt-5.1`–`gpt-5.6` re-accept `temperature`/`topP` when reasoning effort is `none`.

`multiAgent: OpenAIModel.MultiAgent(enabled:maxConcurrentSubagents:)` (GPT-5.6 beta) sends `multi_agent` plus the `responses_multi_agent=v1` header; hosted `multi_agent_call` items surface as `providerMetadata["openai"]["multiAgentCall"]` and must not be executed.

**Platform clients:** `OpenAIResponsesClient` (retrieve/delete/cancel/compact/input items/token counting), `OpenAIConversationsClient` (create from `[Message]` or items, get, update metadata, list/add/delete items), `OpenAIVectorStoresClient` (create with expiry, `search(_:query:maxResults:filters:rewriteQuery:)`, attach/detach files), `OpenAIBatchClient`, `OpenAIContainersClient`, `OpenAIModerationsClient` (`Verdict.flagged` + sorted category names), `OpenAIFiles`, `OpenAIVideoModel("sora-2")` (create → poll → download, `remix`/`list`/`delete`).

### Anthropic — `AnthropicModel`

Env `ANTHROPIC_API_KEY`, base `https://api.anthropic.com/v1`. Extra arg `anthropicVersion: String = "2023-06-01"`.

```swift
let m = AnthropicModel("claude-sonnet-5")
```

Reasoning translates to adaptive thinking / `budget_tokens` by model family; output ceilings 4,096 → 128k. Same table drives Bedrock `anthropic.*` ids.

**Tool definition properties** (any tool, built-in or your own) via `Tool.loading(_:)` → `strict`, `defer_loading`, `allowed_callers`, `cache_control`, `eager_input_streaming`; shorthands `.ephemeralCache()` / `.codeExecutionOnly()`. `inputExamples` ship natively as `input_examples`. Newer tool versions carry beta headers automatically: `web_search_20260318`, `web_fetch_20260318`/`20260309`, `code_execution_20260521`/`20260120`, `computer_20251124`, `advisor_20260301`, tool search, and `mcpToolset` (MCP connector, `mcp-client-2025-11-20`).

**Platform clients:** `AnthropicBatchClient` (Message Batches — `create`, `list`, `get`, `results` decoded per JSONL line, `cancel`, `delete`), `AnthropicModelsClient` (`list`/`get`), `AnthropicModel.countTokens(_:tools:system:)`, `AnthropicFiles`, `AnthropicSkills.upload`.

### Google — `GoogleModel`

Env `GOOGLE_GENERATIVE_AI_API_KEY`, base `https://generativelanguage.googleapis.com/v1beta`.

```swift
let m = GoogleModel("gemini-3-pro")
```

`gemini-3*` takes `thinkingLevel`; other budget models cap thinking tokens (32,768 for 2.5 Pro / `gemini-3-pro-image`, 24,576 otherwise). Reasoning surfaces as `.reasoningDelta`.

### Google Interactions API — `GoogleInteractionsModel`

Google's newer primitive (`POST /v1beta/interactions`, GA June 2026); `generateContent` is now labelled legacy but fully supported, so `GoogleModel` stays. Both conform to `LanguageModel`.

```swift
var chat = GoogleInteractionsModel("gemini-3.6-flash", store: true)
chat.previousInteractionID = result.providerMetadata?["google"]?["interactionId"]?.stringValue
let agent = GoogleInteractionsModel.agent("deep-research-preview-04-2026", agentConfig: …)
```

- **`store` defaults to `false` here** (Google's API defaults it to `true`, retaining 55d paid / 1d free) — opt in deliberately. `previousInteractionID` needs `store: true`.
- `background: true` for long runs; `create(_:)` / `retrieve(_:)` / `cancel(_:)` / `delete(_:)` manage stored interactions.
- Wire: messages become `input` steps (`user_input` / `model_output` / `function_call` / `function_result` with `call_id`), tools are `{type: "function", name, description, parameters}`, structured output is `response_json_schema`, reasoning is `thinking_level` (minimal/low/medium/high), tool choice maps auto/any/none/validated.
- SSE decoding: `interaction.created` → provider metadata (`interactionId`), `step.start/delta/stop` → text, reasoning (`thought` steps), and tool calls, `interaction.completed|failed|cancelled` → finish + usage (`total_input_tokens`, `total_output_tokens`, `total_thought_tokens`, `total_cached_tokens`).
- Agents replace `generation_config` with `agent_config`; pass it via `.agent(agentConfig:)`.

### Google embeddings, media, and platform

- `GoogleEmbeddingModel("gemini-embedding-001", taskType:title:outputDimensionality:)` — one text → `embedContent`, many → `batchEmbedContents`.
- `GoogleImageModel` (Imagen `:predict`), `GoogleVideoModel` (Veo `:predictLongRunning` + polling + URI download), `GoogleSpeechModel` (Gemini TTS via audio modality on `generateContent`), `GoogleMusicModel` (Lyria `:predict`).
- `GoogleFilesClient` — two-step resumable upload (`X-Goog-Upload-Protocol: resumable` then finalize), `get`/`list`/`delete`, plus `waitUntilActive` for `PROCESSING → ACTIVE`.
- `GoogleCachedContentClient` — `create(ttlSeconds:)`, `list`, `get`, `updateTTL`, `delete`; reference the returned `cachedContents/…` name via `providerOptions["cachedContent"]`.
- `GoogleBatchClient` — `create` (`batchGenerateContent`), `createEmbeddings` (`asyncBatchEmbedContent`), `get`, `list`, `cancel`, `delete`.
- `GoogleModel.countTokens(_:systemInstruction:)`.

### Google Vertex — `GoogleVertexModel`

`init(_ modelID:project:location:apiKey:accessToken:baseURL:headers:urlSession:)`. `provider == "google.vertex"`. Env `GOOGLE_VERTEX_PROJECT`, `GOOGLE_VERTEX_LOCATION` (default `global`), `GOOGLE_VERTEX_API_KEY`. Auth precedence: `apiKey`/env → `x-goog-api-key`; else `accessToken` → bearer; else none. `baseURL` is `URL?`.

```swift
let m = GoogleVertexModel("gemini-3-pro", project: "my-proj", location: "us-central1")
```

### Azure OpenAI — `AzureOpenAIProvider` (factory, not a model)

A provider object you call to mint deployment-backed models. `init(resourceName:apiKey:baseURL:apiVersion:useDeploymentBasedUrls:headers:urlSession:)`. Env `AZURE_RESOURCE_NAME`, `AZURE_API_KEY`. Default URL `https://{resource}.openai.azure.com/openai`.

```swift
let azure = AzureOpenAIProvider(resourceName: "my-resource")
let m = azure("my-gpt-5-deployment")
let emb = azure.textEmbeddingModel("my-embed-deployment")
```

`callAsFunction` == `languageModel(_:)` → `OpenAIChatModel`. Also `textEmbeddingModel(_:)`.

### Bedrock — `BedrockModel`

`init(_ modelID:apiKey:region:accessKeyID:secretAccessKey:sessionToken:baseURL:headers:urlSession:)`. Two auth modes: `AWS_BEARER_TOKEN_BEDROCK` (API key), or IAM creds via `accessKeyID`/`secretAccessKey`/`sessionToken` (or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) which trigger **SigV4 signing** for the region. When both are present, SigV4 wins. `region: String = "us-east-1"`, default base `https://bedrock-runtime.{region}.amazonaws.com`. Reasoning by id prefix: `anthropic.*` → Claude thinking, `openai.*` → `reasoning_effort`, else generic `reasoningConfig` (`xhigh` → `max`). Guardrail `trace` + `cacheWriteInputTokens` land on `result.providerMetadata["bedrock"]`.

```swift
let key = BedrockModel("anthropic.claude-sonnet-5", region: "us-west-2")            // API key
let iam = BedrockModel("anthropic.claude-sonnet-5", region: "us-west-2",
                       accessKeyID: "AKIA…", secretAccessKey: "…")                   // SigV4
```

### Bedrock Mantle — `BedrockMantleProvider`

`init(region:apiKey:baseURL:headers:urlSession:)`, `region` default `"us-east-1"`, key from `AWS_BEARER_TOKEN_BEDROCK`. Targets the `bedrock-mantle` endpoint: base `https://bedrock-mantle.{region}.api.aws`, `/v1` for the OpenAI surfaces and `/anthropic/v1` for Messages (a `baseURL` already ending in either is normalized, not re-suffixed). `callAsFunction` == `languageModel(_:)` == `responses(_:)` → `OpenAIModel`; `chat(_:)` → `OpenAIChatModel`; `messages(_:anthropicVersion:)` → `AnthropicModel`. All report `provider == "bedrock"`. API-key auth only — SigV4 stays on `BedrockModel`. Model ids have no region prefix (no CRIS on this endpoint). Responses-API reasoning effort goes through `providerOptions["reasoning"]["effort"]`; `store`/`previous_response_id` likewise. No guardrails or prompt routing on this endpoint.

```swift
let bedrock = BedrockMantleProvider(region: "us-east-1")
let responses = bedrock("openai.gpt-oss-120b")
let messages = bedrock.messages("anthropic.claude-sonnet-4-6-v1")
```

### xAI — `XaiModel` (Responses) / `.chat`

Env `XAI_API_KEY`, base `https://api.x.ai/v1`. Same `OpenAIModel`-style split. Provider-executed `XaiModel.Tools` (`webSearch`/`xSearch` with image/video toggles, `codeExecution`, `fileSearch`, `mcpServer`) are the current search path; `SearchParameters` (live search) is **deprecated** — use the tools. Unified `topK` reaches Grok's `top_k`; `min_p`/`logprobs` ride `providerOptions`.

```swift
let m = XaiModel("grok-4.5")
let chat = XaiModel.chat("grok-4.5")
```

`grok-4.20` date-stamped `-reasoning`/`-non-reasoning` variants ignore the `reasoning` param (behavior baked in).

**Beyond chat:** `XaiImageModel` (`/images/generations` + edits), `XaiSpeechModel` (`grok-tts`), `XaiTranscriptionModel` (`grok-stt`), `XaiVideoModel` (`generateVideos`/`editVideo`/`extendVideo`), `XaiRealtimeModel`. `XaiModel.chat(...).submitDeferredCompletion(_:)` runs a completion async; `compactResponse(previousResponseID:)` compacts stored context; `retrieveResponse(_:)` / `deleteResponse(_:)` manage stored responses.

**Platform REST clients** (Files/Batch/Deferred need a non-ZDR account):
- `XaiFilesClient` — `upload` (`expiresAfter`, sent before the file field as xAI requires), `list` (limit/order/sortBy/paginationToken/after/filter), `get`, `update(_:body:)`, `download`, `delete`.
- `XaiBatchClient` — `create`, `list`, `get`, `requests`, `addRequests`, `results`, `cancel` (`POST /v1/batches/{id}:cancel`).
- `XaiModelsClient` — `/v1/models` plus `language-models`, `image-generation-models`, `video-generation-models` (list + get); the richer catalogs carry modalities, pricing, fingerprint, aliases.
- `XaiPlatformClient` — `apiKeyInfo()`, `tokenizeText(_:model:)` (or `tokenizeText(body:)` passthrough), `createPhoneNumber` (**`/v2/phone-numbers`**), `referCall`/`hangUpCall`, `voices()`/`voice(_:)`/`customVoices()`.
- `XaiCollectionsClient` — **two services**: management (`https://management-api.x.ai/v1`, `XAI_MANAGEMENT_API_KEY`, falls back to `apiKey`) for `create`/`list`/`get`/`update`(PUT)/`delete`/`addDocument`(`POST .../documents/{file_id}` — id in the **path**)/`listDocuments`/`document`/`documents`(`:batchGet`)/`regenerateIndices`(PATCH)/`removeDocument`, and inference (`https://api.x.ai/v1`, `XAI_API_KEY`) for `search`. All management calls accept `teamID:`.

Not wrapped: chunked upload (`/v1/files:initialize`, `:uploadChunks`) and the `PUT /v1/files/{id}` body — xAI documents the routes without payload fields.

### Meta — `MetaModel` (Responses) / `.chat`

Env `MODEL_API_KEY` (falls back to `META_API_KEY`), base `https://api.meta.ai/v1`. Muse Spark models: `muse-spark-1.2`, `muse-spark-1.1`, `muse-spark-1.2-contributor` (discounted, Meta trains on your traffic). 1,048,576-token context. Reuses the `OpenAIModel` Responses engine through a dialect: system prompts always ride the `developer` role, a custom `reasoning:` is sent as `reasoning.effort` plus a `summary` (`.none` is dropped — the API 400s on it; leaving `reasoning:` unset sends neither, so no summary streams), and `temperature`/`topP` still go through.

```swift
let m = MetaModel("muse-spark-1.2")
let chat = MetaModel.chat("muse-spark-1.2")
```

Provider-executed `MetaModel.Tools`: `webSearch(searchContextSize:userLocation:)` (citations arrive as `.source`; Responses-only) and `toolSearch(execution:description:parameters:)` (one per request). Deferred tools work through the shared `defer_loading` path.

`store`, `include: ["reasoning.encrypted_content"]`, `previous_response_id`, `background`, and `prompt_cache_retention` ride `providerOptions`. `include` + `previous_response_id` together is a 400, as are `logprobs` and `truncation: "auto"`.

### Groq / DeepSeek / Mistral / Perplexity — chat-completions wrappers

All wrap `OpenAIChatModel`; `init(_ modelID:apiKey:baseURL:headers:urlSession:)`.

| Pack | Env | Base URL |
| --- | --- | --- |
| `GroqModel` | `GROQ_API_KEY` | `https://api.groq.com/openai/v1` |
| `DeepSeekModel` | `DEEPSEEK_API_KEY` | `https://api.deepseek.com` |
| `MistralModel` | `MISTRAL_API_KEY` | `https://api.mistral.ai/v1` |
| `PerplexityModel` | `PERPLEXITY_API_KEY` | `https://api.perplexity.ai` |

```swift
let g = GroqModel("llama-3.3-70b-versatile")
let d = DeepSeekModel("deepseek-reasoner")
let p = PerplexityModel("sonar-pro")
```

Mistral maps `reasoning` → `reasoning_effort` only on `mistral-small-latest`, `mistral-small-2603`, `mistral-medium-3`, `mistral-medium-3.5`. Groq's compound models take server tools via `GroqModel.Tools.browserSearch()` / `codeExecution()`. Perplexity has no upstream tool calling; citations + the richer `search_results` (title + url) surface as `.source`, and `images` / `related_questions` (request them with `return_images` / `return_related_questions` in `providerOptions`) land on `result.providerMetadata["perplexity"]`.

### Cohere — `CohereModel`

Env `COHERE_API_KEY`, base `https://api.cohere.com/v2`. Companion `CohereEmbeddingModel` (same env/base) and `CohereRerankingModel`. Citations surface as sources.

```swift
let m = CohereModel("command-a")
```

## First-class models on compatible endpoints

Named services have dedicated `LanguageModel` types even when they share the chat-completions wire:

| Model | Endpoint | Key from |
| --- | --- | --- |
| `TogetherAIModel` | `api.together.xyz/v1` | `TOGETHER_API_KEY` |
| `FireworksModel` | `api.fireworks.ai/inference/v1` | `FIREWORKS_API_KEY` |
| `CerebrasModel` | `api.cerebras.ai/v1` | `CEREBRAS_API_KEY` |
| `OpenRouterModel` | `openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| `DeepInfraModel` | `api.deepinfra.com/v1/openai` | `DEEPINFRA_API_KEY` |
| `BasetenModel` | `inference.baseten.co/v1` | `BASETEN_API_KEY` |
| `VercelModel` | `api.v0.dev/v1` | `VERCEL_API_KEY` |
| `AIGatewayModel` | `ai-gateway.vercel.sh/v1` | `AI_GATEWAY_API_KEY` |
| `SarvamModel` | `api.sarvam.ai/v1` | `SARVAM_API_KEY` |
| `MoonshotModel` | `api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| `AlibabaModel` | `dashscope-intl.aliyuncs.com/compatible-mode/v1` | `ALIBABA_API_KEY` |
| `HuggingFaceModel` | `router.huggingface.co/v1` (Responses wire) | `HUGGINGFACE_API_KEY` |
| `OllamaModel` | `localhost:11434/v1` | no key |
| `LMStudioModel` | `localhost:1234/v1` | no key |

Each initializer is `init(_ modelID:apiKey:baseURL:headers:urlSession:)`; `baseURL: nil` selects the provider default.

```swift
let hosted = TogetherAIModel("MiniMaxAI/MiniMax-M3")
let local = OllamaModel("gemma4")
```

## Custom compatible endpoints — `OpenAICompatibleProvider`

Provider object for a custom chat-completions endpoint. `callAsFunction(_:)` == `languageModel(_:)` → `OpenAIChatModel`; also `textEmbeddingModel(_:)`. General init:

```swift
let p = OpenAICompatibleProvider(
  name: "myhost",
  baseURL: URL(string: "https://api.example.com/v1")!,
  apiKey: "sk-...",
  headers: [:], queryParams: [:]
)
let m = p("openai/gpt-oss-20b")
```

The old named factory methods remain deprecated for source compatibility. New code should use the first-class model types.

## Sarvam trio (Indic)

One key `SARVAM_API_KEY` across all three surfaces.

- Chat: `SarvamModel("sarvam-105b")`. `sarvam-30b` (64K) / `sarvam-105b` (128K) are reasoning models; `reasoning` → `reasoning_effort`, thinking streams back as `.reasoningDelta`.
- TTS: `SarvamSpeechModel(_ modelID: String = "bulbul:v3", apiKey:targetLanguage: String = "en-IN", baseURL:headers:urlSession:)`, base `https://api.sarvam.ai`. Language override + Sarvam knobs (`pitch`, `loudness`, `temperature`, `speech_sample_rate`) via `providerOptions`.
- STT: `SarvamTranscriptionModel(_ modelID: String = "saaras:v3", apiKey:baseURL:headers:urlSession:)`. `language_code`/`mode` via `providerOptions`; `mode` ∈ `transcribe|translate|verbatim|translit|codemix`.

```swift
let tts = SarvamSpeechModel("bulbul:v3", targetLanguage: "hi-IN")
let audio = try await generateSpeech(model: tts, text: "नमस्ते", voice: "anushka", outputFormat: "mp3")

let stt = SarvamTranscriptionModel("saaras:v3")
let r = try await transcribe(model: stt, audio: audioData, mediaType: "audio/wav",
                             providerOptions: ["language_code": "hi-IN", "mode": "transcribe"])
```

## Registry — `provider:model` strings

`ProviderRegistry` resolves `"provider:model"` (separator `:` by default) to a typed model. Build it from `ProviderRegistry.Provider` factories; `customProvider(...)` gives per-id aliases with a `fallback`.

```swift
let registry = ProviderRegistry(providers: [
  "openai": ProviderRegistry.Provider { OpenAIModel($0) },
  "anthropic": customProvider(
    languageModels: ["fast": AnthropicModel("claude-haiku-4.5")],
    fallback: ProviderRegistry.Provider { AnthropicModel($0) }
  )
])

let m = try registry.languageModel("anthropic:fast")
let m2 = try registry.languageModel("openai:gpt-5.1")
```

Lookups: `languageModel`, `embeddingModel`, `imageModel`, `speechModel`, `transcriptionModel`, `rerankingModel` — each throws `AIError.invalidRequest` on a bad id, unknown provider, or a provider that lacks that model kind. `ProviderRegistry.Provider(_:)` has a shorthand init taking just a language-model closure.

## Gotchas

- `apiKey: nil` resolves to the env var and defaults to `""` (empty), not a crash — a missing key surfaces later as `AIError.http(status: 401, ...)`.
- `OpenAIModel`, `XaiModel`, and `MetaModel` default to the **Responses** API; call `.chat(...)` for Chat Completions. `Groq/DeepSeek/Mistral/Perplexity` are always Chat Completions.
- `baseURL` type differs: `URL?` on `OpenAIModel`/`GoogleVertexModel`/`BedrockModel`/`AzureOpenAIProvider` (nil → default), non-optional `URL` with a default on the others.
- `AzureOpenAIProvider` and custom `OpenAICompatibleProvider` values are provider objects, not models — call them (`provider("id")`) to get an `OpenAIChatModel`.
- Vertex `provider` is `"google.vertex"`; if you register it under `"google"` in a `ProviderRegistry`, the `provider:model` prefix and the pack's `provider` string will differ.
- Perplexity: no tool calling upstream; passing `tools:` won't produce tool calls.
- Embeddings on OpenAI, Azure OpenAI, Cohere, Voyage (`VoyageEmbeddingModel`), Alibaba (`AlibabaEmbeddingModel`, native DashScope endpoint), and any OpenAI-compatible endpoint. Reranking on Cohere and Voyage (`VoyageRerankingModel`).
- `AlibabaModel` first-classes Qwen thinking: the unified `reasoning` maps to `enable_thinking` + `thinking_budget`. `HuggingFaceModel` wraps the router's OpenAI **Responses** endpoint (not chat), and has no embeddings.
- `OpenAIResponsesClient` manages stored/background responses: `retrieve`, `delete`, `cancel`, `compact`, `listInputItems`, `countInputTokens`.

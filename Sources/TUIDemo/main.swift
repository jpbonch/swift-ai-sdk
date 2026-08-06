import AI
import AITUI
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments)

func flag(_ name: String, environmentKey: String? = nil) -> Bool {
    if flags.contains(name) { return true }
    guard let environmentKey else { return false }
    return environment[environmentKey] != nil
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

if flag("--help") || flag("-h") {
    print("""
    tui-demo — an interactive terminal agent built on swift-ai-sdk.

    USAGE
      swift run tui-demo [backend] [--model <id>]

    BACKENDS
      --ollama       Local models via Ollama. No API key needed.
      --openai       OpenAI. Needs OPENAI_API_KEY.
      --anthropic    Anthropic. Needs ANTHROPIC_API_KEY.
      --on-device    Apple Intelligence, fully on-device.
      --pcc          Apple Private Cloud Compute.

    With no backend flag the demo picks the first that is usable:
    Anthropic, then OpenAI, then a running Ollama.

    OPTIONS
      --model <id>   Model id. Defaults per backend; also reads AI_MODEL.
      --list         List the models a running Ollama has pulled.

    ENVIRONMENT
      OPENAI_API_KEY, ANTHROPIC_API_KEY, AI_MODEL,
      OLLAMA_HOST (default http://localhost:11434),
      TUI_DEMO_APPROVAL=1 to require approval for the weather tool.
    """)
    exit(0)
}

let ollamaHost = environment["OLLAMA_HOST"] ?? "http://localhost:11434"

func ollamaBaseURL() -> URL {
    URL(string: "\(ollamaHost)/v1") ?? URL(string: "http://localhost:11434/v1")!
}

func installedOllamaModels() async -> [String]? {
    guard let url = URL(string: "\(ollamaHost)/api/tags") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse, http.statusCode == 200,
          let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return nil
    }
    return (payload["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
}

if flag("--list") {
    guard let models = await installedOllamaModels() else {
        fail("No Ollama server at \(ollamaHost). Start it with `ollama serve`.")
    }
    if models.isEmpty {
        print("Ollama is running at \(ollamaHost) but has no models. Try `ollama pull qwen3`.")
    } else {
        print("Models available at \(ollamaHost):")
        for name in models.sorted() { print("  \(name)") }
    }
    exit(0)
}

let weather = Tool(
    name: "weather",
    description: "Get the current weather in a location.",
    parameters: [
        "type": "object",
        "properties": ["location": ["type": "string"]],
        "required": ["location"]
    ],
    needsApproval: environment["TUI_DEMO_APPROVAL"] != nil
) { arguments in
    let location = arguments["location"]?.stringValue ?? "unknown"
    let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location
    guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1") else {
        throw AIError.invalidRequest("Could not build a weather URL for \(location).")
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("swift-ai-sdk tui-demo", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw AIError.http(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: "Weather lookup for \(location) failed."
        )
    }
    let payload = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let current = payload["current_condition"]?[0] else {
        throw AIError.decoding("No current conditions for \(location).")
    }
    return .object([
        "location": .string(location),
        "temperatureF": current["temp_F"] ?? .null,
        "temperatureC": current["temp_C"] ?? .null,
        "description": current["weatherDesc"]?[0]?["value"] ?? .null,
        "humidity": current["humidity"] ?? .null,
        "windMph": current["windspeedMiles"] ?? .null
    ])
}
.idempotent()

func onDeviceModel() -> any AI.LanguageModel {
    #if canImport(FoundationModels)
    guard #available(iOS 26.0, macOS 26.0, *) else {
        fail("On-device models need macOS 26 / iOS 26 or later.")
    }

    if flag("--pcc", environmentKey: "AI_PCC") {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, *) else {
            fail("Private Cloud Compute needs macOS 27 / iOS 27 or later.")
        }
        let pcc = PrivateCloudComputeLanguageModel()
        guard pcc.isAvailable else {
            fail("Private Cloud Compute is unavailable: \(pcc.availability)")
        }
        return FoundationModelsModel(privateCloudCompute: pcc)
        #else
        fail("Private Cloud Compute needs a newer Swift compiler.")
        #endif
    }

    guard FoundationModelsModel.isAvailable else {
        fail("Apple Intelligence is unavailable: \(FoundationModelsModel.availability)")
    }
    return FoundationModelsModel()
    #else
    fail("This build has no FoundationModels framework.")
    #endif
}

func ollamaModel() async -> any AI.LanguageModel {
    guard let installed = await installedOllamaModels() else {
        fail("""
        No Ollama server at \(ollamaHost).

          brew install ollama && ollama serve
          ollama pull qwen3

        Or use a hosted model: --openai (OPENAI_API_KEY) or --anthropic (ANTHROPIC_API_KEY).
        """)
    }
    guard !installed.isEmpty else {
        fail("Ollama at \(ollamaHost) has no models pulled. Try `ollama pull qwen3`.")
    }

    let requested = option("--model") ?? environment["AI_MODEL"]
    guard let requested else {
        return OllamaModel(installed[0], baseURL: ollamaBaseURL())
    }
    let match = installed.first { $0 == requested || $0.hasPrefix("\(requested):") }
    guard let match else {
        fail("""
        Ollama has no model \"\(requested)\". Installed: \(installed.sorted().joined(separator: ", "))
        Pull it with `ollama pull \(requested)`.
        """)
    }
    return OllamaModel(match, baseURL: ollamaBaseURL())
}

struct Backend {
    var model: any AI.LanguageModel
    var title: String
    var contextWindow: Int
}

func selectBackend() async -> Backend {
    let requested = option("--model") ?? environment["AI_MODEL"]

    if flag("--on-device", environmentKey: "AI_ON_DEVICE") || flag("--pcc", environmentKey: "AI_PCC") {
        let model = onDeviceModel()
        let onDeviceOnly = !flag("--pcc", environmentKey: "AI_PCC")
        return Backend(
            model: model,
            title: onDeviceOnly ? "On-Device Agent" : "Private Cloud Compute Agent",
            contextWindow: onDeviceOnly ? 8_192 : model.contextWindow
        )
    }

    if flag("--anthropic") {
        guard let key = environment["ANTHROPIC_API_KEY"] else {
            fail("--anthropic needs ANTHROPIC_API_KEY.")
        }
        let model = AnthropicModel(requested ?? "claude-sonnet-5", apiKey: key)
        return Backend(model: model, title: "Anthropic Agent", contextWindow: model.contextWindow)
    }

    if flag("--openai") {
        guard let key = environment["OPENAI_API_KEY"] else {
            fail("--openai needs OPENAI_API_KEY.")
        }
        let model = OpenAIModel(requested ?? "gpt-5.1", apiKey: key)
        return Backend(model: model, title: "OpenAI Agent", contextWindow: model.contextWindow)
    }

    if flag("--ollama") {
        let model = await ollamaModel()
        return Backend(
            model: model,
            title: "Ollama Agent (\(model.modelID))",
            contextWindow: model.contextWindow
        )
    }

    if let key = environment["ANTHROPIC_API_KEY"] {
        let model = AnthropicModel(requested ?? "claude-sonnet-5", apiKey: key)
        return Backend(model: model, title: "Anthropic Agent", contextWindow: model.contextWindow)
    }
    if let key = environment["OPENAI_API_KEY"] {
        let model = OpenAIModel(requested ?? "gpt-5.1", apiKey: key)
        return Backend(model: model, title: "OpenAI Agent", contextWindow: model.contextWindow)
    }
    if let installed = await installedOllamaModels(), !installed.isEmpty {
        let model = await ollamaModel()
        return Backend(
            model: model,
            title: "Ollama Agent (\(model.modelID))",
            contextWindow: model.contextWindow
        )
    }

    fail("""
    No model available. Pick one:

      OPENAI_API_KEY=…     swift run tui-demo --openai
      ANTHROPIC_API_KEY=…  swift run tui-demo --anthropic
      ollama serve         swift run tui-demo --ollama      # local, no key
      swift run tui-demo --on-device                        # Apple Intelligence

    `swift run tui-demo --help` lists every option.
    """)
}

let backend = await selectBackend()

let agent = Agent(
    model: backend.model,
    instructions: """
    You are a helpful terminal assistant. Answer in markdown. Keep replies short \
    unless asked for detail. Use the weather tool when asked about conditions \
    somewhere — do not guess.
    """,
    tools: [weather],
    maxOutputTokens: 2048,
    compaction: Compaction()
)

do {
    try await runAgentTUI(
        title: environment["TUI_DEMO_TITLE"] ?? backend.title,
        agent: agent,
        contextSize: backend.contextWindow
    )
} catch let error as AgentTUIError {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

import AI
import Foundation

enum ContextUploadsAndTransportExamples {

    static let weather = Tool(
        name: "weather",
        description: "Get the weather.",
        parameters: [
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"]
        ]
    ) { arguments, options in
        [
            "city": arguments["city"] ?? .null,
            "unit": options.context?["unit"] ?? .string("celsius")
        ]
    }
    .withContextSchema(Schema.object(["apiKey": .string(), "unit": .string()]))
    .describing { context in
        "Get the weather in \(context?["unit"]?.stringValue ?? "celsius")."
    }

    static func runtimeContext(model: any LanguageModel) async throws {
        let result = try await generateText(
            model: model,
            prompt: "Look up the weather in a few cities.",
            tools: [weather],
            toolsContext: ["weather": ["apiKey": "k-123", "unit": "fahrenheit"]],
            prepareStep: { context in
                let calls = context.runtimeContext?["toolCalls"]?.intValue ?? 0
                guard calls < 5 else {
                    return PrepareStepResult(tools: [])
                }
                return PrepareStepResult(
                    runtimeContext: ["toolCalls": .number(Double(calls + 1))]
                )
            },
            runtimeContext: ["tenant": "acme", "toolCalls": .number(0)],
            telemetry: TelemetrySettings(
                functionID: "weather-lookup",
                metadata: ["team": "ios"],
                includeRuntimeContext: ["tenant"],
                includeToolsContext: ["weather"]
            )
        )
        print(result.steps.last?.runtimeContext ?? .null)
    }

    static func dynamicTools(names: [String]) -> [any AIToolProtocol] {
        names.map { name in
            Tool.dynamic(name: name, description: "Runtime tool \(name).") { input, _ in
                ["echo": input]
            }
        }
    }

    static func uploadAndReference(model: any LanguageModel, pdf: Data) async throws {
        let uploaded = try await uploadFile(
            api: OpenAIFiles(),
            data: pdf,
            filename: "report.pdf",
            mediaType: "application/pdf"
        )

        let result = try await generateText(
            model: model,
            messages: [Message(role: .user, content: [
                .text("Summarize this."),
                .file(uploaded.file(mediaType: "application/pdf"))
            ])]
        )
        print(result.text)
    }

    static func remoteAttachmentOnBedrock() async throws {
        guard let url = URL(string: "https://example.com/chart.png") else { return }
        let result = try await generateText(
            model: BedrockModel("anthropic.claude-sonnet-4-5-20250929-v1:0"),
            messages: [Message(role: .user, content: [
                .text("What does this chart show?"),
                .image(ImageContent(url: url))
            ])]
        )
        print(result.text)
    }

    static func transportWithFreshCredentials(token: @escaping @Sendable () async -> String) -> HTTPChatTransport {
        guard let api = URL(string: "https://example.com/api/chat") else {
            fatalError("invalid api url")
        }
        return HTTPChatTransport(
            api: api,
            prepareSendMessagesRequest: { request in
                PreparedChatRequest(
                    headers: ["authorization": "Bearer \(await token())"],
                    body: ["messages": .array(request.messages.suffix(10).map(\.wire))]
                )
            },
            prepareReconnectToStreamRequest: { chatID in
                PreparedChatRequest(
                    api: URL(string: "https://example.com/resume/\(chatID)"),
                    headers: ["authorization": "Bearer \(await token())"]
                )
            }
        )
    }

    static func helpers(tools: [any AIToolProtocol]) {
        let active = filterActiveTools(tools, activeTools: ["weather"])
        let messageID = createIdGenerator(prefix: "msg", separator: "_")()
        print(active.count, messageID, generateId())
    }
}

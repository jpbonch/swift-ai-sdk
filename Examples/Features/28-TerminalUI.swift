import AI
import AITUI
import Foundation

enum TerminalUIExamples {

    static let weather = Tool(
        name: "weather",
        description: "Get the weather in a location.",
        parameters: [
            "type": "object",
            "properties": ["location": ["type": "string"]],
            "required": ["location"]
        ],
        needsApproval: true
    ) { arguments in
        ["location": arguments["location"] ?? .string("unknown"), "temperatureF": 72]
    }

    @MainActor
    static func localAgent() async throws {
        let agent = Agent(
            model: OpenAIModel("gpt-5"),
            instructions: "You are a helpful terminal assistant. Answer in markdown.",
            tools: [weather]
        )
        try await runAgentTUI(title: "Weather Agent", agent: agent)
    }

    @MainActor
    static func remoteAgent() async throws {
        guard let api = URL(string: "https://example.com/api/chat") else { return }
        try await runAgentTUI(
            title: "Remote Agent",
            transport: HTTPChatTransport(api: api)
        )
    }

    @MainActor
    static func displayOptions() async throws {
        let agent = Agent(model: OpenAIModel("gpt-5"), tools: [weather])
        try await runAgentTUI(
            title: "Assistant",
            agent: agent,
            tools: .autoCollapsed,
            reasoning: .collapsed,
            responseStatistics: .outputTokenCount,
            contextSize: 200_000
        )
    }

    static func renderTranscriptWithoutTheApp(_ messages: [UIMessage]) -> [String] {
        TranscriptRenderer.lines(
            for: messages,
            width: 80,
            options: TerminalTranscriptOptions(tools: .full, reasoning: .hidden)
        ).map { $0.render(styled: true) }
    }
}

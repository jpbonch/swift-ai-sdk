import AI

enum MetaExamples {
    static func textAndReasoning() async throws {
        let result = streamText(
            model: MetaModel("muse-spark-1.2"),
            prompt: "Prove that the square root of 2 is irrational.",
            reasoning: .high
        )
        for try await part in result.fullStream {
            if case .reasoningDelta(let text) = part { print(text, terminator: "") }
            if case .textDelta(let text) = part { print(text, terminator: "") }
        }
    }

    static func searchGrounding() async throws {
        let result = try await generateText(
            model: MetaModel("muse-spark-1.2"),
            prompt: "What are the latest developments in AI regulation?",
            tools: [
                MetaModel.Tools.webSearch(
                    searchContextSize: "high",
                    userLocation: .init(country: "GB", city: "London")
                )
            ]
        )
        print(result.text)
        for source in result.sources {
            print("- \(source.title ?? source.url): \(source.url)")
        }
    }

    static func statelessReasoningReplay() async throws {
        let result = try await generateText(
            model: MetaModel("muse-spark-1.2"),
            prompt: "Plan a three-step migration and call the tools you need.",
            providerOptions: .object([
                "store": .bool(false),
                "include": .array([.string("reasoning.encrypted_content")])
            ])
        )
        print(result.text)
    }

    static func chatCompletions() async throws {
        let result = try await generateText(
            model: MetaModel.chat("muse-spark-1.2"),
            prompt: "Say hello."
        )
        print(result.text)
    }
}

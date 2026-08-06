import AI

enum AmazonBedrockMantleExamples {
    static func responses() async throws {
        let bedrock = BedrockMantleProvider(region: "us-east-1")
        let result = streamText(
            model: bedrock("openai.gpt-oss-120b"),
            prompt: "Explain Swift actors.",
            providerOptions: ["reasoning": ["effort": "high"], "store": false]
        )
        for try await text in result.textStream {
            print(text, terminator: "")
        }
    }

    static func anthropicMessages() async throws {
        let bedrock = BedrockMantleProvider(region: "us-east-1")
        let result = try await generateText(
            model: bedrock.messages("anthropic.claude-sonnet-4-6-v1"),
            prompt: "Summarize the CAP theorem in two sentences.",
            reasoning: .medium
        )
        print(result.text)
    }
}

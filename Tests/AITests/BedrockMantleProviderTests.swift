import XCTest
@testable import AI

final class BedrockMantleProviderTests: XCTestCase {

    private let prompt = LanguageModelRequest(messages: [.user("Hi")])

    func testResponsesRequestTargetsMantleOpenAIPath() throws {
        let provider = BedrockMantleProvider(region: "eu-west-1", apiKey: "bedrock-key")
        let config = OpenAIModel.ResponsesConfig(
            apiKey: provider.resolvedAPIKey,
            baseURL: provider.openAIBaseURL,
            headers: provider.headers,
            urlSession: .shared
        )
        let urlRequest = try OpenAIModel.buildResponsesRequest(
            config, modelID: "openai.gpt-oss-120b", request: prompt
        )
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://bedrock-mantle.eu-west-1.api.aws/v1/responses"
        )
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer bedrock-key"
        )
        XCTAssertEqual(provider.responses("openai.gpt-oss-120b").provider, "bedrock")
    }

    func testChatCompletionsRequestTargetsMantleOpenAIPath() {
        let provider = BedrockMantleProvider(apiKey: "bedrock-key")
        let model = provider.chat("deepseek.v3-2")
        XCTAssertEqual(
            model.requestURL(path: "chat/completions").absoluteString,
            "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions"
        )
        XCTAssertEqual(model.provider, "bedrock")
    }

    func testMessagesRequestUsesAnthropicPathAndHeaders() throws {
        let provider = BedrockMantleProvider(region: "ap-south-1", apiKey: "bedrock-key")
        let model = provider.messages("anthropic.claude-sonnet-4-6-v1")
        let urlRequest = try model.buildURLRequest(prompt)
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://bedrock-mantle.ap-south-1.api.aws/anthropic/v1/messages"
        )
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "bedrock-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(model.provider, "bedrock")
    }

    func testMantleModelIDsResolveClaudeCapabilities() {
        let caps = AnthropicModel.modelCapabilities("anthropic.claude-sonnet-4-6-v1")
        XCTAssertTrue(caps.supportsAdaptiveThinking)
        XCTAssertEqual(caps.maxOutputTokens, 128_000)
    }

    func testCustomBaseURLIsNotDoublePrefixed() {
        let openAIStyle = BedrockMantleProvider(
            baseURL: URL(string: "https://bedrock-mantle.us-west-2.api.aws/v1")!
        )
        XCTAssertEqual(
            openAIStyle.openAIBaseURL.absoluteString,
            "https://bedrock-mantle.us-west-2.api.aws/v1"
        )
        XCTAssertEqual(
            openAIStyle.anthropicBaseURL.absoluteString,
            "https://bedrock-mantle.us-west-2.api.aws/anthropic/v1"
        )

        let anthropicStyle = BedrockMantleProvider(
            baseURL: URL(string: "https://gateway.internal/anthropic/v1/")!
        )
        XCTAssertEqual(
            anthropicStyle.openAIBaseURL.absoluteString, "https://gateway.internal/v1"
        )
        XCTAssertEqual(
            anthropicStyle.anthropicBaseURL.absoluteString,
            "https://gateway.internal/anthropic/v1"
        )
    }

    func testDefaultProviderReadsBedrockAPIKeyEnvironment() {
        let provider = BedrockMantleProvider(apiKey: "  spaced-key  ")
        XCTAssertEqual(provider.resolvedAPIKey, "spaced-key")
        XCTAssertEqual(
            BedrockMantleProvider(region: "sa-east-1").openAIBaseURL.host,
            "bedrock-mantle.sa-east-1.api.aws"
        )
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BedrockMantleProvider: Sendable {
    public var region: String
    public var apiKey: String?
    public var baseURL: URL?
    public var headers: [String: String]
    private let urlSession: URLSession

    public init(
        region: String = "us-east-1",
        apiKey: String? = nil,
        baseURL: URL? = nil,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.region = region
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["AWS_BEARER_TOKEN_BEDROCK"]
        self.baseURL = baseURL
        self.headers = headers
        self.urlSession = urlSession
    }

    public func callAsFunction(_ modelID: String) -> OpenAIModel {
        languageModel(modelID)
    }

    public func languageModel(_ modelID: String) -> OpenAIModel {
        responses(modelID)
    }

    public func responses(_ modelID: String) -> OpenAIModel {
        OpenAIModel(
            modelID,
            apiKey: resolvedAPIKey,
            baseURL: openAIBaseURL,
            headers: headers,
            urlSession: urlSession,
            providerName: Self.providerName
        )
    }

    public func chat(_ modelID: String) -> OpenAIChatModel {
        OpenAIChatModel(
            modelID,
            apiKey: resolvedAPIKey,
            baseURL: openAIBaseURL,
            headers: headers,
            queryParams: [:],
            urlSession: urlSession,
            providerName: Self.providerName
        )
    }

    public func messages(
        _ modelID: String,
        anthropicVersion: String = "2023-06-01"
    ) -> AnthropicModel {
        AnthropicModel(
            modelID,
            apiKey: resolvedAPIKey,
            baseURL: anthropicBaseURL,
            anthropicVersion: anthropicVersion,
            headers: headers,
            urlSession: urlSession,
            providerName: Self.providerName
        )
    }

    static let providerName = "bedrock"

    var resolvedAPIKey: String {
        (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var endpoint: String {
        var prefix = baseURL?.absoluteString
            ?? "https://bedrock-mantle.\(region).api.aws"
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if prefix.hasSuffix("/anthropic/v1") {
            prefix.removeLast("/anthropic/v1".count)
        } else if prefix.hasSuffix("/v1") {
            prefix.removeLast("/v1".count)
        }
        return prefix
    }

    var openAIBaseURL: URL {
        URL(string: "\(endpoint)/v1") ?? Self.fallbackBaseURL
    }

    var anthropicBaseURL: URL {
        URL(string: "\(endpoint)/anthropic/v1") ?? Self.fallbackBaseURL
    }

    private static let fallbackBaseURL = URL(string: "https://bedrock-mantle.us-east-1.api.aws/v1")!
}

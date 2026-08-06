import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MetaModel: LanguageModel {
    public let provider = "meta"
    public let modelID: String

    private enum Backend: Sendable {
        case responses(OpenAIModel)
        case chat(OpenAIChatModel)
    }

    private let backend: Backend

    public static let defaultBaseURL = URL(string: "https://api.meta.ai/v1")!

    public init(
        _ modelID: String,
        apiKey: String? = nil,
        baseURL: URL = MetaModel.defaultBaseURL,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.backend = .responses(OpenAIModel(
            modelID,
            apiKey: Self.resolvedAPIKey(apiKey),
            baseURL: baseURL,
            headers: headers,
            urlSession: urlSession,
            providerName: "meta",
            dialect: Self.dialect
        ))
    }

    public static func chat(
        _ modelID: String,
        apiKey: String? = nil,
        baseURL: URL = MetaModel.defaultBaseURL,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) -> MetaModel {
        MetaModel(modelID: modelID, chatEngine: OpenAIChatModel(
            modelID,
            apiKey: resolvedAPIKey(apiKey),
            baseURL: baseURL,
            headers: headers,
            queryParams: [:],
            urlSession: urlSession,
            providerName: "meta"
        ))
    }

    private init(modelID: String, chatEngine: OpenAIChatModel) {
        self.modelID = modelID
        self.backend = .chat(chatEngine)
    }

    public func stream(
        _ request: LanguageModelRequest
    ) async throws -> AsyncThrowingStream<StreamPart, Error> {
        switch backend {
        case .responses(let engine):
            return try await engine.stream(request)
        case .chat(let engine):
            let hosted = request.providerTools(for: "meta").map(\.name)
            guard hosted.isEmpty else {
                throw AIError.unsupportedFunctionality(
                    "Meta serves \(hosted.joined(separator: ", ")) on the Responses API only. "
                    + "Build the model with MetaModel(...) instead of MetaModel.chat(...)."
                )
            }
            return try await engine.stream(request)
        }
    }

    static let dialect = OpenAIModel.ResponsesDialect(
        provider: "meta",
        alwaysReasons: true,
        supportsDisablingReasoning: false,
        dropsSamplingWhenReasoning: false
    )

    static func resolvedAPIKey(_ apiKey: String?) -> String {
        if let apiKey { return apiKey }
        let environment = ProcessInfo.processInfo.environment
        return environment["MODEL_API_KEY"] ?? environment["META_API_KEY"] ?? ""
    }
}

public extension MetaModel {
    enum Tools {
        public struct UserLocation: Sendable {
            public var country: String?
            public var region: String?
            public var city: String?
            public var timezone: String?

            public init(
                country: String? = nil,
                region: String? = nil,
                city: String? = nil,
                timezone: String? = nil
            ) {
                self.country = country
                self.region = region
                self.city = city
                self.timezone = timezone
            }

            var wire: JSONValue {
                var body: [String: JSONValue] = ["type": "approximate"]
                if let country { body["country"] = .string(country) }
                if let region { body["region"] = .string(region) }
                if let city { body["city"] = .string(city) }
                if let timezone { body["timezone"] = .string(timezone) }
                return .object(body)
            }
        }

        public static func webSearch(
            searchContextSize: String? = nil,
            userLocation: UserLocation? = nil,
            name: String = "web_search"
        ) -> ProviderDefinedTool {
            var args: [String: JSONValue] = ["type": "web_search"]
            if let searchContextSize { args["search_context_size"] = .string(searchContextSize) }
            if let userLocation { args["user_location"] = userLocation.wire }
            return ProviderDefinedTool(
                provider: "meta", id: "meta.web_search", name: name, args: .object(args)
            )
        }

        public static func toolSearch(
            execution: String? = nil,
            description: String? = nil,
            parameters: JSONValue? = nil,
            name: String = "tool_search"
        ) -> ProviderDefinedTool {
            var args: [String: JSONValue] = ["type": "tool_search"]
            if let execution { args["execution"] = .string(execution) }
            if let description { args["description"] = .string(description) }
            if let parameters { args["parameters"] = parameters }
            return ProviderDefinedTool(
                provider: "meta", id: "meta.tool_search", name: name, args: .object(args)
            )
        }
    }
}

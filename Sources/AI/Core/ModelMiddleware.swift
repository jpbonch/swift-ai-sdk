import Foundation

public struct EmbeddingModelMiddleware: Sendable {
    public var transformInput: (@Sendable ([String]) async throws -> [String])?
    public var wrapEmbed: (
        @Sendable ([String], @Sendable ([String]) async throws -> EmbeddingResponse)
            async throws -> EmbeddingResponse
    )?

    public init(
        transformInput: (@Sendable ([String]) async throws -> [String])? = nil,
        wrapEmbed: (
            @Sendable ([String], @Sendable ([String]) async throws -> EmbeddingResponse)
                async throws -> EmbeddingResponse
        )? = nil
    ) {
        self.transformInput = transformInput
        self.wrapEmbed = wrapEmbed
    }
}

public struct WrappedEmbeddingModel: EmbeddingModel {
    public let base: any EmbeddingModel
    public let middleware: [EmbeddingModelMiddleware]

    public var provider: String { base.provider }
    public var modelID: String { base.modelID }

    public init(base: any EmbeddingModel, middleware: [EmbeddingModelMiddleware]) {
        self.base = base
        self.middleware = middleware
    }

    public func embed(_ texts: [String]) async throws -> EmbeddingResponse {
        var transformed = texts
        for entry in middleware {
            if let transform = entry.transformInput {
                transformed = try await transform(transformed)
            }
        }

        let base = self.base
        var next: @Sendable ([String]) async throws -> EmbeddingResponse = {
            try await base.embed($0)
        }
        for entry in middleware.reversed() {
            guard let wrap = entry.wrapEmbed else { continue }
            let inner = next
            next = { try await wrap($0, inner) }
        }
        return try await next(transformed)
    }
}

public func wrapEmbeddingModel(
    model: any EmbeddingModel,
    middleware: [EmbeddingModelMiddleware]
) -> any EmbeddingModel {
    WrappedEmbeddingModel(base: model, middleware: middleware)
}

public extension EmbeddingModelMiddleware {
    static func defaultSettings(
        maxBatchSize: Int? = nil,
        transform: (@Sendable ([String]) -> [String])? = nil
    ) -> EmbeddingModelMiddleware {
        EmbeddingModelMiddleware(transformInput: { texts in
            var texts = transform?(texts) ?? texts
            if let maxBatchSize, maxBatchSize > 0, texts.count > maxBatchSize {
                texts = Array(texts.prefix(maxBatchSize))
            }
            return texts
        })
    }
}

public struct ImageModelMiddleware: Sendable {
    public var transformRequest: (@Sendable (ImageModelRequest) async throws -> ImageModelRequest)?
    public var wrapGenerate: (
        @Sendable (
            ImageModelRequest,
            @Sendable (ImageModelRequest) async throws -> ImageModelResponse
        ) async throws -> ImageModelResponse
    )?

    public init(
        transformRequest: (@Sendable (ImageModelRequest) async throws -> ImageModelRequest)? = nil,
        wrapGenerate: (
            @Sendable (
                ImageModelRequest,
                @Sendable (ImageModelRequest) async throws -> ImageModelResponse
            ) async throws -> ImageModelResponse
        )? = nil
    ) {
        self.transformRequest = transformRequest
        self.wrapGenerate = wrapGenerate
    }
}

public struct WrappedImageModel: ImageModel {
    public let base: any ImageModel
    public let middleware: [ImageModelMiddleware]

    public var provider: String { base.provider }
    public var modelID: String { base.modelID }

    public init(base: any ImageModel, middleware: [ImageModelMiddleware]) {
        self.base = base
        self.middleware = middleware
    }

    public func generateImages(_ request: ImageModelRequest) async throws -> ImageModelResponse {
        var transformed = request
        for entry in middleware {
            if let transform = entry.transformRequest {
                transformed = try await transform(transformed)
            }
        }

        let base = self.base
        var next: @Sendable (ImageModelRequest) async throws -> ImageModelResponse = {
            try await base.generateImages($0)
        }
        for entry in middleware.reversed() {
            guard let wrap = entry.wrapGenerate else { continue }
            let inner = next
            next = { try await wrap($0, inner) }
        }
        return try await next(transformed)
    }
}

public func wrapImageModel(
    model: any ImageModel,
    middleware: [ImageModelMiddleware]
) -> any ImageModel {
    WrappedImageModel(base: model, middleware: middleware)
}

public struct WrappedProvider: Sendable {
    public var languageModelMiddleware: [LanguageModelMiddleware]
    public var embeddingModelMiddleware: [EmbeddingModelMiddleware]
    public var imageModelMiddleware: [ImageModelMiddleware]

    private let provider: ProviderRegistry.Provider

    public init(
        provider: ProviderRegistry.Provider,
        languageModelMiddleware: [LanguageModelMiddleware] = [],
        embeddingModelMiddleware: [EmbeddingModelMiddleware] = [],
        imageModelMiddleware: [ImageModelMiddleware] = []
    ) {
        self.provider = provider
        self.languageModelMiddleware = languageModelMiddleware
        self.embeddingModelMiddleware = embeddingModelMiddleware
        self.imageModelMiddleware = imageModelMiddleware
    }

    public var wrapped: ProviderRegistry.Provider {
        let languageMiddleware = languageModelMiddleware
        let embeddingMiddleware = embeddingModelMiddleware
        let imageMiddleware = imageModelMiddleware
        let base = provider

        return ProviderRegistry.Provider(
            languageModel: base.languageModel.map { factory in
                { @Sendable id in
                    wrapLanguageModel(model: try factory(id), middleware: languageMiddleware)
                }
            },
            embeddingModel: base.embeddingModel.map { factory in
                { @Sendable id in
                    wrapEmbeddingModel(model: try factory(id), middleware: embeddingMiddleware)
                }
            },
            imageModel: base.imageModel.map { factory in
                { @Sendable id in
                    wrapImageModel(model: try factory(id), middleware: imageMiddleware)
                }
            },
            speechModel: base.speechModel,
            transcriptionModel: base.transcriptionModel,
            rerankingModel: base.rerankingModel
        )
    }
}

public func wrapProvider(
    provider: ProviderRegistry.Provider,
    languageModelMiddleware: [LanguageModelMiddleware] = [],
    embeddingModelMiddleware: [EmbeddingModelMiddleware] = [],
    imageModelMiddleware: [ImageModelMiddleware] = []
) -> ProviderRegistry.Provider {
    WrappedProvider(
        provider: provider,
        languageModelMiddleware: languageModelMiddleware,
        embeddingModelMiddleware: embeddingModelMiddleware,
        imageModelMiddleware: imageModelMiddleware
    ).wrapped
}

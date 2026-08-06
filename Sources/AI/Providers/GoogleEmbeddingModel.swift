import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleEmbeddingModel: EmbeddingModel {
    public let provider = "google"
    public let modelID: String

    public enum TaskType: String, Sendable {
        case retrievalQuery = "RETRIEVAL_QUERY"
        case retrievalDocument = "RETRIEVAL_DOCUMENT"
        case semanticSimilarity = "SEMANTIC_SIMILARITY"
        case classification = "CLASSIFICATION"
        case clustering = "CLUSTERING"
        case questionAnswering = "QUESTION_ANSWERING"
        case factVerification = "FACT_VERIFICATION"
        case codeRetrievalQuery = "CODE_RETRIEVAL_QUERY"
    }

    let http: GoogleHTTP
    private let taskType: TaskType?
    private let title: String?
    private let outputDimensionality: Int?

    public init(
        _ modelID: String = "gemini-embedding-001",
        apiKey: String? = nil,
        taskType: TaskType? = nil,
        title: String? = nil,
        outputDimensionality: Int? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.taskType = taskType
        self.title = title
        self.outputDimensionality = outputDimensionality
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func embed(_ texts: [String]) async throws -> EmbeddingResponse {
        guard !texts.isEmpty else { return EmbeddingResponse(embeddings: []) }

        if texts.count == 1 {
            let json = try await http.send(
                "POST", "models/\(modelID):embedContent",
                json: .object(requestFields(for: texts[0]))
            )
            guard let values = json["embedding"]?["values"]?.arrayValue else {
                throw AIError.decoding("Google embedContent returned no embedding values")
            }
            return EmbeddingResponse(
                embeddings: [values.compactMap(\.doubleValue)],
                usage: Usage(
                    inputTokens: json["usageMetadata"]?["promptTokenCount"]?.intValue ?? 0,
                    outputTokens: 0
                )
            )
        }

        let requests = texts.map { text -> JSONValue in
            var fields = requestFields(for: text)
            fields["model"] = .string("models/\(modelID)")
            return .object(fields)
        }
        let json = try await http.send(
            "POST", "models/\(modelID):batchEmbedContents",
            json: .object(["requests": .array(requests)])
        )
        guard let embeddings = json["embeddings"]?.arrayValue else {
            throw AIError.decoding("Google batchEmbedContents returned no embeddings")
        }
        return EmbeddingResponse(
            embeddings: embeddings.map { $0["values"]?.arrayValue?.compactMap(\.doubleValue) ?? [] },
            usage: Usage(
                inputTokens: json["usageMetadata"]?["promptTokenCount"]?.intValue ?? 0,
                outputTokens: 0
            )
        )
    }

    func requestFields(for text: String) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "content": .object(["parts": .array([.object(["text": .string(text)])])])
        ]
        if let taskType { fields["taskType"] = .string(taskType.rawValue) }
        if let title { fields["title"] = .string(title) }
        if let outputDimensionality {
            fields["outputDimensionality"] = .number(Double(outputDimensionality))
        }
        return fields
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleImageModel: ImageModel {
    public let provider = "google"
    public let modelID: String

    let http: GoogleHTTP

    public init(
        _ modelID: String = "imagen-4.0-generate-001",
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func generateImages(_ request: ImageModelRequest) async throws -> ImageModelResponse {
        let json = try await http.send(
            "POST", "models/\(modelID):predict", json: Self.requestBody(request)
        )
        let predictions = json["predictions"]?.arrayValue ?? []
        let images = predictions.compactMap { prediction -> Data? in
            guard let encoded = prediction["bytesBase64Encoded"]?.stringValue
                ?? prediction["image"]?["bytesBase64Encoded"]?.stringValue
            else { return nil }
            return Data(base64Encoded: encoded)
        }
        guard !images.isEmpty else {
            throw AIError.decoding("Imagen returned no images")
        }
        return ImageModelResponse(
            images: images,
            revisedPrompts: predictions.map { $0["prompt"]?.stringValue }
        )
    }

    static func requestBody(_ request: ImageModelRequest) -> JSONValue {
        var instance: [String: JSONValue] = ["prompt": .string(request.prompt)]
        if let reference = request.images.first,
           let data = reference.data {
            instance["image"] = .object([
                "bytesBase64Encoded": .string(data.base64EncodedString())
            ])
        }

        var parameters: [String: JSONValue] = ["sampleCount": .number(Double(max(request.n, 1)))]
        if let aspectRatio = request.aspectRatio {
            parameters["aspectRatio"] = .string(aspectRatio)
        }
        if let size = request.size { parameters["imageSize"] = .string(size) }
        if let seed = request.seed { parameters["seed"] = .number(Double(seed)) }
        if case .object(let options)? = request.providerOptions {
            for (key, value) in options { parameters[key] = value }
        }

        return .object([
            "instances": .array([.object(instance)]),
            "parameters": .object(parameters)
        ])
    }
}

public struct GoogleVideoModel: VideoModel {
    public let provider = "google"
    public let modelID: String

    let http: GoogleHTTP
    private let pollInterval: Duration
    private let pollTimeout: Duration

    public init(
        _ modelID: String = "veo-3.1-generate-preview",
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        pollInterval: Duration = .seconds(5),
        pollTimeout: Duration = .seconds(600),
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func generateVideos(_ request: VideoModelRequest) async throws -> VideoModelResponse {
        let created = try await http.send(
            "POST", "models/\(modelID):predictLongRunning", json: Self.requestBody(request)
        )
        guard let operation = created["name"]?.stringValue else {
            throw AIError.decoding("Veo returned no operation name")
        }

        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while true {
            try await Task.sleep(for: pollInterval)
            let status = try await http.send("GET", operation)
            if status["done"]?.boolValue == true {
                if let error = status["error"] {
                    throw AIError.transport("Veo generation failed: \(error)")
                }
                return try await Self.videos(from: status, http: http)
            }
            guard ContinuousClock.now < deadline else {
                throw AIError.transport("Veo generation timed out after \(pollTimeout)")
            }
        }
    }

    static func requestBody(_ request: VideoModelRequest) -> JSONValue {
        var instance: [String: JSONValue] = ["prompt": .string(request.prompt)]
        if let image = request.image, let data = image.data {
            instance["image"] = .object([
                "bytesBase64Encoded": .string(data.base64EncodedString()),
                "mimeType": .string(image.mediaType ?? "image/png")
            ])
        }

        var parameters: [String: JSONValue] = [:]
        if let aspectRatio = request.aspectRatio {
            parameters["aspectRatio"] = .string(aspectRatio)
        }
        if let seconds = request.duration {
            parameters["durationSeconds"] = .number(Double(seconds))
        }
        if case .object(let options)? = request.providerOptions {
            for (key, value) in options { parameters[key] = value }
        }

        var body: [String: JSONValue] = ["instances": .array([.object(instance)])]
        if !parameters.isEmpty { body["parameters"] = .object(parameters) }
        return .object(body)
    }

    static func videos(
        from status: JSONValue, http: GoogleHTTP
    ) async throws -> VideoModelResponse {
        let samples = status["response"]?["generateVideoResponse"]?["generatedSamples"]?.arrayValue
            ?? status["response"]?["generatedSamples"]?.arrayValue
            ?? []
        var videos: [Data] = []
        for sample in samples {
            if let encoded = sample["video"]?["bytesBase64Encoded"]?.stringValue,
               let data = Data(base64Encoded: encoded) {
                videos.append(data)
                continue
            }
            if let uri = sample["video"]?["uri"]?.stringValue {
                videos.append(try await http.download(uri))
            }
        }
        guard !videos.isEmpty else {
            throw AIError.decoding("Veo returned no videos")
        }
        return VideoModelResponse(videos: videos)
    }
}

public struct GoogleSpeechModel: SpeechModel {
    public let provider = "google"
    public let modelID: String

    let http: GoogleHTTP

    public init(
        _ modelID: String = "gemini-3.1-flash-tts-preview",
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func generateSpeech(
        _ request: SpeechModelRequest
    ) async throws -> SpeechModelResponse {
        let json = try await http.send(
            "POST", "models/\(modelID):generateContent",
            json: Self.requestBody(request, modelID: modelID)
        )
        let parts = json["candidates"]?.arrayValue?.first?["content"]?["parts"]?.arrayValue ?? []
        for part in parts {
            guard let inline = part["inlineData"] ?? part["inline_data"],
                  let encoded = inline["data"]?.stringValue,
                  let audio = Data(base64Encoded: encoded)
            else { continue }
            return SpeechModelResponse(
                audio: audio,
                mediaType: inline["mimeType"]?.stringValue
                    ?? inline["mime_type"]?.stringValue
                    ?? "audio/pcm"
            )
        }
        throw AIError.decoding("Gemini TTS returned no audio data")
    }

    static func requestBody(_ request: SpeechModelRequest, modelID: String) -> JSONValue {
        var speechConfig: [String: JSONValue] = [:]
        if let voice = request.voice {
            speechConfig["voiceConfig"] = .object([
                "prebuiltVoiceConfig": .object(["voiceName": .string(voice)])
            ])
        }
        if let instructions = request.instructions {
            speechConfig["voiceInstructions"] = .string(instructions)
        }

        var generationConfig: [String: JSONValue] = [
            "responseModalities": .array([.string("AUDIO")])
        ]
        if !speechConfig.isEmpty {
            generationConfig["speechConfig"] = .object(speechConfig)
        }
        if case .object(let options)? = request.providerOptions {
            for (key, value) in options { generationConfig[key] = value }
        }

        return .object([
            "contents": .array([
                .object([
                    "role": .string("user"),
                    "parts": .array([.object(["text": .string(request.text)])])
                ])
            ]),
            "generationConfig": .object(generationConfig)
        ])
    }
}

public struct GoogleMusicModel: Sendable {
    public let provider = "google"
    public let modelID: String

    let http: GoogleHTTP

    public init(
        _ modelID: String = "lyria-3-clip-preview",
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared
    ) {
        self.modelID = modelID
        self.http = GoogleHTTP(
            apiKey: apiKey, baseURL: baseURL, headers: headers, urlSession: urlSession
        )
    }

    public func generateMusic(
        prompt: String,
        negativePrompt: String? = nil,
        seed: Int? = nil,
        providerOptions: JSONValue? = nil
    ) async throws -> Data {
        var instance: [String: JSONValue] = ["prompt": .string(prompt)]
        if let negativePrompt { instance["negative_prompt"] = .string(negativePrompt) }
        var parameters: [String: JSONValue] = [:]
        if let seed { parameters["seed"] = .number(Double(seed)) }
        if case .object(let options)? = providerOptions {
            for (key, value) in options { parameters[key] = value }
        }

        var body: [String: JSONValue] = ["instances": .array([.object(instance)])]
        if !parameters.isEmpty { body["parameters"] = .object(parameters) }

        let json = try await http.send(
            "POST", "models/\(modelID):predict", json: .object(body)
        )
        let predictions = json["predictions"]?.arrayValue ?? []
        for prediction in predictions {
            guard let encoded = prediction["bytesBase64Encoded"]?.stringValue
                ?? prediction["audioContent"]?.stringValue,
                  let data = Data(base64Encoded: encoded)
            else { continue }
            return data
        }
        throw AIError.decoding("Lyria returned no audio")
    }
}

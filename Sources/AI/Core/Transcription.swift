import Foundation

public protocol TranscriptionModel: Sendable {
    var provider: String { get }
    var modelID: String { get }
    func transcribe(_ request: TranscriptionModelRequest) async throws -> TranscriptionModelResponse
}

public struct TranscriptionModelRequest: Sendable {
    public var audio: Data
    public var mediaType: String
    public var providerOptions: JSONValue?

    public init(audio: Data, mediaType: String, providerOptions: JSONValue? = nil) {
        self.audio = audio
        self.mediaType = mediaType
        self.providerOptions = providerOptions
    }
}

public struct TranscriptionSegment: Sendable, Hashable {
    public var text: String
    public var startSecond: Double
    public var endSecond: Double

    public init(text: String, startSecond: Double, endSecond: Double) {
        self.text = text
        self.startSecond = startSecond
        self.endSecond = endSecond
    }
}

public struct TranscriptionModelResponse: Sendable, Hashable {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String?
    public var durationInSeconds: Double?

    public init(
        text: String,
        segments: [TranscriptionSegment] = [],
        language: String? = nil,
        durationInSeconds: Double? = nil
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.durationInSeconds = durationInSeconds
    }
}

public struct TranscriptionResult: Sendable {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String?
    public var durationInSeconds: Double?
}

public func detectAudioMediaType(_ audio: Data) -> String? {
    guard audio.count >= 12 else { return nil }
    let bytes = [UInt8](audio.prefix(12))

    func matches(_ ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard bytes.count >= offset + expected.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }

    if matches("ftyp", at: 4) { return "audio/mp4" }
    if matches("RIFF", at: 0), matches("WAVE", at: 8) { return "audio/wav" }
    if matches("OggS", at: 0) { return "audio/ogg" }
    if matches("fLaC", at: 0) { return "audio/flac" }
    if matches("ID3", at: 0) { return "audio/mpeg" }
    if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "audio/mpeg" }
    return nil
}

public func transcribe(
    model: any TranscriptionModel,
    audio: Data,
    mediaType: String,
    providerOptions: JSONValue? = nil,
    maxRetries: Int = 2
) async throws -> TranscriptionResult {
    var mediaType = mediaType
    let isGeneric = mediaType.isEmpty
        || mediaType == "application/octet-stream"
        || mediaType == "audio/*"
    // Only fill in a type the caller did not supply. An explicit `video/mp4` or
    // `video/quicktime` is a deliberate choice, and every ISO-BMFF file carries
    // the same `ftyp` marker, so sniffing cannot tell them apart.
    if isGeneric, let sniffed = detectAudioMediaType(audio) {
        mediaType = sniffed
    }

    let request = TranscriptionModelRequest(
        audio: audio,
        mediaType: mediaType,
        providerOptions: providerOptions
    )
    let response = try await Retry.withRetries(maxRetries) {
        try await model.transcribe(request)
    }
    guard !response.text.isEmpty else {
        throw AIError.decoding("Transcription response contained no text")
    }
    return TranscriptionResult(
        text: response.text,
        segments: response.segments,
        language: response.language,
        durationInSeconds: response.durationInSeconds
    )
}

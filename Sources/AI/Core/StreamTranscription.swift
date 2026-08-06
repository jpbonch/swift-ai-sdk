import Foundation

public enum TranscriptionStreamPart: Sendable, Hashable {
    case transcriptDelta(String)
    case partialTranscript(String)
    case segment(TranscriptionSegment)
    case language(String)
    case speechStart(secondsFromStart: Double)
    case speechEnd(secondsFromStart: Double)
    case finish(TranscriptionModelResponse)
}

public protocol StreamingTranscriptionModel: TranscriptionModel {
    func streamTranscribe(
        _ request: StreamTranscriptionModelRequest
    ) async throws -> AsyncThrowingStream<TranscriptionStreamPart, Error>
}

public struct StreamTranscriptionModelRequest: Sendable {
    public var audio: AsyncThrowingStream<Data, Error>
    public var mediaType: String
    public var providerOptions: JSONValue?

    public init(
        audio: AsyncThrowingStream<Data, Error>,
        mediaType: String,
        providerOptions: JSONValue? = nil
    ) {
        self.audio = audio
        self.mediaType = mediaType
        self.providerOptions = providerOptions
    }
}

public struct StreamTranscriptionResult: Sendable {
    public let fullStream: AsyncThrowingStream<TranscriptionStreamPart, Error>

    private let collected: TranscriptionCollector

    init(
        fullStream: AsyncThrowingStream<TranscriptionStreamPart, Error>,
        collector: TranscriptionCollector
    ) {
        self.fullStream = fullStream
        self.collected = collector
    }

    public var textStream: AsyncThrowingStream<String, Error> {
        let parts = fullStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await part in parts {
                        if case .transcriptDelta(let delta) = part { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var text: String {
        get async throws { try await result().text }
    }

    public var segments: [TranscriptionSegment] {
        get async throws { try await result().segments }
    }

    public var language: String? {
        get async throws { try await result().language }
    }

    public func result() async throws -> TranscriptionResult {
        try await collected.consume(fullStream)
    }
}

actor TranscriptionCollector {
    private var finished: Result<TranscriptionResult, Error>?
    private var isDraining = false

    func consume(
        _ stream: AsyncThrowingStream<TranscriptionStreamPart, Error>
    ) async throws -> TranscriptionResult {
        if let finished { return try finished.get() }
        guard !isDraining else {
            throw AIError.invalidRequest(
                "streamTranscribe fullStream is single-consumer: read it once, "
                + "or await the result promises instead."
            )
        }
        isDraining = true

        var text = ""
        var segments: [TranscriptionSegment] = []
        var language: String?
        var duration: Double?

        do {
            for try await part in stream {
                switch part {
                case .transcriptDelta(let delta):
                    text += delta
                case .segment(let segment):
                    segments.append(segment)
                case .language(let value):
                    language = value
                case .finish(let response):
                    if !response.text.isEmpty { text = response.text }
                    if !response.segments.isEmpty { segments = response.segments }
                    language = response.language ?? language
                    duration = response.durationInSeconds ?? duration
                case .partialTranscript, .speechStart, .speechEnd:
                    break
                }
            }
        } catch {
            finished = .failure(error)
            throw error
        }

        let result = TranscriptionResult(
            text: text, segments: segments, language: language, durationInSeconds: duration
        )
        finished = .success(result)
        return result
    }
}

public func streamTranscribe(
    model: any TranscriptionModel,
    audio: AsyncThrowingStream<Data, Error>,
    mediaType: String,
    providerOptions: JSONValue? = nil
) throws -> StreamTranscriptionResult {
    guard let streaming = model as? any StreamingTranscriptionModel else {
        throw AIError.invalidRequest(
            "Model '\(model.provider)/\(model.modelID)' does not support streaming transcription."
        )
    }

    let relayBox = AudioRelayBox()
    let relay = AsyncThrowingStream<Data, Error> { continuation in
        let pump = Task {
            do {
                for try await chunk in audio {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        relayBox.pump = pump
        continuation.onTermination = { _ in pump.cancel() }
    }

    let request = StreamTranscriptionModelRequest(
        audio: relay, mediaType: mediaType, providerOptions: providerOptions
    )

    let stream = AsyncThrowingStream<TranscriptionStreamPart, Error> { continuation in
        let task = Task {
            do {
                let source = try await streaming.streamTranscribe(request)
                for try await part in source { continuation.yield(part) }
                relayBox.cancel()
                continuation.finish()
            } catch {
                relayBox.cancel()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            relayBox.cancel()
        }
    }

    return StreamTranscriptionResult(fullStream: stream, collector: TranscriptionCollector())
}

final class AudioRelayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var pump: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return task }
        set { lock.lock(); task = newValue; lock.unlock() }
    }

    func cancel() {
        pump?.cancel()
    }
}

import XCTest
@testable import AI

private struct FakeStreamingTranscriptionModel: StreamingTranscriptionModel {
    let provider = "fake"
    let modelID = "fake-live"
    var failBeforeStreaming = false
    let observed = AudioObserver()

    func transcribe(_ request: TranscriptionModelRequest) async throws -> TranscriptionModelResponse {
        TranscriptionModelResponse(text: "batch")
    }

    func streamTranscribe(
        _ request: StreamTranscriptionModelRequest
    ) async throws -> AsyncThrowingStream<TranscriptionStreamPart, Error> {
        if failBeforeStreaming {
            throw AIError.http(status: 401, body: "missing key")
        }
        let audio = request.audio
        let observed = self.observed
        return AsyncThrowingStream { continuation in
            let task = Task {
                for try await chunk in audio {
                    await observed.record(chunk)
                    continuation.yield(.partialTranscript("partial"))
                    continuation.yield(.transcriptDelta(String(decoding: chunk, as: UTF8.self)))
                }
                continuation.yield(.segment(
                    TranscriptionSegment(text: "hello", startSecond: 0, endSecond: 1)
                ))
                continuation.yield(.language("en"))
                continuation.yield(.finish(TranscriptionModelResponse(
                    text: "hello world", language: "en", durationInSeconds: 1.5
                )))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor AudioObserver {
    private(set) var chunks: [Data] = []
    func record(_ chunk: Data) { chunks.append(chunk) }
}

private struct BatchOnlyModel: TranscriptionModel {
    let provider = "fake"
    let modelID = "batch"
    func transcribe(_ request: TranscriptionModelRequest) async throws -> TranscriptionModelResponse {
        TranscriptionModelResponse(text: "batch")
    }
}

private func audioStream(_ chunks: [String]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        continuation.finish()
    }
}

final class StreamTranscriptionTests: XCTestCase {

    func testFullStreamCarriesEveryPart() async throws {
        let model = FakeStreamingTranscriptionModel()
        let result = try streamTranscribe(
            model: model, audio: audioStream(["hello ", "world"]), mediaType: "audio/pcm"
        )

        var parts: [TranscriptionStreamPart] = []
        for try await part in result.fullStream { parts.append(part) }

        XCTAssertTrue(parts.contains(.partialTranscript("partial")))
        XCTAssertTrue(parts.contains(.transcriptDelta("hello ")))
        XCTAssertTrue(parts.contains(.transcriptDelta("world")))
        XCTAssertTrue(parts.contains(.language("en")))
        guard case .finish(let response)? = parts.last else {
            return XCTFail("expected a finish part, got \(String(describing: parts.last))")
        }
        XCTAssertEqual(response.text, "hello world")
    }

    func testResultPromiseConsumesTheStreamWithoutDeadlocking() async throws {
        let model = FakeStreamingTranscriptionModel()
        let result = try streamTranscribe(
            model: model, audio: audioStream(["hello ", "world"]), mediaType: "audio/pcm"
        )

        let text = try await result.text
        XCTAssertEqual(text, "hello world")

        let language = try await result.language
        XCTAssertEqual(language, "en")
        let again = try await result.text
        XCTAssertEqual(again, "hello world", "the result is cached after the first drain")
    }

    func testTextStreamYieldsOnlyFinalizedDeltas() async throws {
        let model = FakeStreamingTranscriptionModel()
        let result = try streamTranscribe(
            model: model, audio: audioStream(["a", "b"]), mediaType: "audio/pcm"
        )

        var text = ""
        for try await delta in result.textStream { text += delta }
        XCTAssertEqual(text, "ab", "partial transcripts must not be concatenated")
    }

    func testAudioIsForwardedToTheModel() async throws {
        let model = FakeStreamingTranscriptionModel()
        let result = try streamTranscribe(
            model: model, audio: audioStream(["one", "two"]), mediaType: "audio/pcm"
        )
        _ = try await result.text
        let chunks = await model.observed.chunks
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
    }

    func testFailureBeforeStreamingCancelsTheAudioProducer() async {
        let cancelled = CancellationFlag()
        let audio = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in Task { await cancelled.mark() } }
            continuation.yield(Data("chunk".utf8))
        }

        var model = FakeStreamingTranscriptionModel()
        model.failBeforeStreaming = true

        do {
            let result = try streamTranscribe(
                model: model, audio: audio, mediaType: "audio/pcm"
            )
            for try await _ in result.fullStream {}
            XCTFail("expected the model error to surface")
        } catch let error as AIError {
            guard case .http(let status, _) = error else {
                return XCTFail("expected an http error, got \(error)")
            }
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }

        for _ in 0..<20 where await !cancelled.value {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didCancel = await cancelled.value
        XCTAssertTrue(didCancel, "a failed setup must not leave the audio producer hanging")
    }

    func testBatchOnlyModelsAreRejected() {
        XCTAssertThrowsError(
            try streamTranscribe(
                model: BatchOnlyModel(), audio: audioStream(["x"]), mediaType: "audio/pcm"
            )
        ) { error in
            guard case AIError.invalidRequest(let message) = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("does not support streaming"), message)
        }
    }
}

private actor CancellationFlag {
    private(set) var value = false
    func mark() { value = true }
}

final class DeepgramLiveTranscriptionTests: XCTestCase {

    func testLiveURLUsesWebSocketSchemeAndOptions() {
        let model = DeepgramTranscriptionModel("nova-3", apiKey: "k")
        let request = StreamTranscriptionModelRequest(
            audio: audioStream([]),
            mediaType: "audio/pcm",
            providerOptions: ["language": "en-US", "punctuate": .bool(true)]
        )
        let urlRequest = model.buildLiveURLRequest(request)
        let url = try? XCTUnwrap(urlRequest.url?.absoluteString)

        XCTAssertTrue(url?.hasPrefix("wss://api.deepgram.com/v1/listen?") == true, url ?? "")
        XCTAssertTrue(url?.contains("model=nova-3") == true, url ?? "")
        XCTAssertTrue(url?.contains("interim_results=true") == true, url ?? "")
        XCTAssertTrue(url?.contains("encoding=linear16") == true, url ?? "")
        XCTAssertTrue(url?.contains("language=en-US") == true, url ?? "")
        XCTAssertTrue(url?.contains("punctuate=true") == true, url ?? "")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Token k")
    }

    func testInterimResultsBecomePartialTranscripts() {
        let event: JSONValue = [
            "type": "Results",
            "is_final": .bool(false),
            "channel": ["alternatives": .array([["transcript": "hello wor"]])]
        ]
        XCTAssertEqual(DeepgramLiveEvent.parts(from: event), [.partialTranscript("hello wor")])
    }

    func testFinalResultsBecomeDeltasAndSegments() {
        let event: JSONValue = [
            "type": "Results",
            "is_final": .bool(true),
            "channel": ["alternatives": .array([[
                "transcript": "hello world",
                "words": .array([
                    ["punctuated_word": "Hello", "start": .number(0), "end": .number(0.4)],
                    ["word": "world", "start": .number(0.4), "end": .number(0.9)]
                ])
            ]])]
        ]
        let parts = DeepgramLiveEvent.parts(from: event)
        XCTAssertEqual(parts.first, .transcriptDelta("hello world"))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(
            parts[1], .segment(TranscriptionSegment(text: "Hello", startSecond: 0, endSecond: 0.4))
        )
        XCTAssertEqual(
            parts[2],
            .segment(TranscriptionSegment(text: "world", startSecond: 0.4, endSecond: 0.9))
        )
    }

    func testSpeechBoundariesAndEmptyTranscripts() {
        XCTAssertEqual(
            DeepgramLiveEvent.parts(from: ["type": "SpeechStarted", "timestamp": .number(1.25)]),
            [.speechStart(secondsFromStart: 1.25)]
        )
        XCTAssertEqual(
            DeepgramLiveEvent.parts(from: [
                "type": "UtteranceEnd", "last_word_end": .number(3.5)
            ]),
            [.speechEnd(secondsFromStart: 3.5)]
        )
        XCTAssertTrue(DeepgramLiveEvent.parts(from: [
            "type": "Results",
            "channel": ["alternatives": .array([["transcript": ""]])]
        ]).isEmpty)
        XCTAssertTrue(DeepgramLiveEvent.isTerminal(["type": "Close"]))
        XCTAssertFalse(DeepgramLiveEvent.isTerminal(["type": "Results"]))
    }
}

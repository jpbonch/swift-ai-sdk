import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension DeepgramTranscriptionModel: StreamingTranscriptionModel {

    public func streamTranscribe(
        _ request: StreamTranscriptionModelRequest
    ) async throws -> AsyncThrowingStream<TranscriptionStreamPart, Error> {
        let socketRequest = buildLiveURLRequest(request)
        let socket = urlSession.webSocketTask(with: socketRequest)

        return AsyncThrowingStream { continuation in
            socket.resume()

            let sender = Task {
                do {
                    for try await chunk in request.audio {
                        guard !Task.isCancelled else { break }
                        try await socket.send(.data(chunk))
                    }
                    let close = Data("{\"type\":\"CloseStream\"}".utf8)
                    try? await socket.send(.data(close))
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }

            let receiver = Task {
                var aggregate = ""
                var segments: [TranscriptionSegment] = []
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let payload: Data?
                        switch message {
                        case .data(let data): payload = data
                        case .string(let text): payload = Data(text.utf8)
                        @unknown default: payload = nil
                        }
                        guard let payload,
                              let value = try? JSONDecoder().decode(JSONValue.self, from: payload)
                        else { continue }

                        let parts = DeepgramLiveEvent.parts(from: value)
                        for part in parts {
                            switch part {
                            case .transcriptDelta(let delta):
                                aggregate += aggregate.isEmpty ? delta : " " + delta
                            case .segment(let segment):
                                segments.append(segment)
                            default:
                                break
                            }
                            continuation.yield(part)
                        }
                        if DeepgramLiveEvent.isTerminal(value) { break }
                    }
                    continuation.yield(.finish(TranscriptionModelResponse(
                        text: aggregate, segments: segments
                    )))
                    continuation.finish()
                } catch {
                    if aggregate.isEmpty {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.yield(.finish(TranscriptionModelResponse(
                            text: aggregate, segments: segments
                        )))
                        continuation.finish()
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
            }

            continuation.onTermination = { _ in
                sender.cancel()
                receiver.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

extension DeepgramTranscriptionModel {
    func buildLiveURLRequest(_ request: StreamTranscriptionModelRequest) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/listen"), resolvingAgainstBaseURL: false
        )!
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }

        var query = [
            URLQueryItem(name: "model", value: modelID),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true")
        ]
        if let encoding = Self.encodingQuery(for: request.mediaType) {
            query.append(URLQueryItem(name: "encoding", value: encoding))
        }
        if case .object(let options)? = request.providerOptions {
            for (key, value) in options.sorted(by: { $0.key < $1.key }) {
                switch value {
                case .string(let text): query.append(URLQueryItem(name: key, value: text))
                case .bool(let flag): query.append(URLQueryItem(name: key, value: "\(flag)"))
                case .number(let number):
                    query.append(URLQueryItem(name: key, value: "\(Int(number))"))
                default: continue
                }
            }
        }
        components.queryItems = query

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        return urlRequest
    }

    static func encodingQuery(for mediaType: String) -> String? {
        switch mediaType {
        case "audio/pcm", "audio/l16", "audio/x-raw": "linear16"
        case "audio/mulaw", "audio/x-mulaw": "mulaw"
        case "audio/opus", "audio/ogg": "opus"
        case "audio/flac": "flac"
        default: nil
        }
    }
}

enum DeepgramLiveEvent {

    static func parts(from value: JSONValue) -> [TranscriptionStreamPart] {
        switch value["type"]?.stringValue {
        case "SpeechStarted":
            let start = value["timestamp"]?.doubleValue ?? 0
            return [.speechStart(secondsFromStart: start)]

        case "UtteranceEnd":
            let end = value["last_word_end"]?.doubleValue ?? 0
            return [.speechEnd(secondsFromStart: end)]

        case "Results", nil:
            guard let alternative = value["channel"]?["alternatives"]?.arrayValue?.first,
                  let transcript = alternative["transcript"]?.stringValue,
                  !transcript.isEmpty
            else { return [] }

            guard value["is_final"]?.boolValue != false else {
                return [.partialTranscript(transcript)]
            }

            var parts: [TranscriptionStreamPart] = [.transcriptDelta(transcript)]
            for word in alternative["words"]?.arrayValue ?? [] {
                guard let text = word["punctuated_word"]?.stringValue
                    ?? word["word"]?.stringValue
                else { continue }
                parts.append(.segment(TranscriptionSegment(
                    text: text,
                    startSecond: word["start"]?.doubleValue ?? 0,
                    endSecond: word["end"]?.doubleValue ?? 0
                )))
            }
            return parts

        case "Metadata":
            guard let language = value["language"]?.stringValue else { return [] }
            return [.language(language)]

        default:
            return []
        }
    }

    static func isTerminal(_ value: JSONValue) -> Bool {
        value["type"]?.stringValue == "Close" || value["from_finalize"]?.boolValue == true
    }
}

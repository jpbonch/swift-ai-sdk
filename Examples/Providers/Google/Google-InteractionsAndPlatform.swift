import AI
import Foundation

enum GoogleInteractionsAndPlatformExamples {

    static func interactions() async throws {
        let model = GoogleInteractionsModel("gemini-3.6-flash")
        let result = streamText(model: model, prompt: "Explain how AI works", reasoning: .medium)
        for try await part in result.fullStream {
            switch part {
            case .reasoningDelta(let thought): print("thinking: \(thought)")
            case .textDelta(let text): print(text, terminator: "")
            default: break
            }
        }
    }

    static func statefulConversation() async throws {
        var chat = GoogleInteractionsModel("gemini-3.6-flash", store: true)

        let first = try await generateText(model: chat, prompt: "I have 2 dogs in my house.")
        chat.previousInteractionID = first.providerMetadata?["google"]?["interactionId"]?.stringValue

        let second = try await generateText(model: chat, prompt: "How many paws are in my house?")
        print(second.text)

        if let id = chat.previousInteractionID {
            try await chat.delete(id)
        }
    }

    static func backgroundAndAgents() async throws {
        let background = GoogleInteractionsModel(
            "gemini-3.6-flash", store: true, background: true
        )
        let started = try await background.create(
            LanguageModelRequest(messages: [.user("Draft a long report.")])
        )
        if let id = started["id"]?.stringValue {
            print(try await background.retrieve(id)["status"] ?? .null)
        }

        let research = GoogleInteractionsModel.agent("deep-research-preview-04-2026")
        let report = try await generateText(
            model: research, prompt: "Compare Swift 6 concurrency proposals"
        )
        print(report.text)
    }

    static func embeddings(chunks: [String]) async throws {
        let model = GoogleEmbeddingModel(
            "gemini-embedding-001",
            taskType: .retrievalDocument,
            outputDimensionality: 768
        )
        let vectors = try await embedMany(model: model, values: chunks)
        print(vectors.embeddings.count)
    }

    static func filesAndCaching(audio: Data, transcript: [Message]) async throws {
        let files = GoogleFilesClient()
        let uploaded = try await files.upload(
            audio, mimeType: "audio/mpeg", displayName: "call.mp3"
        )
        let ready = try await files.waitUntilActive(uploaded.name)

        guard let uri = URL(string: ready.uri) else { return }
        let answer = try await generateText(
            model: GoogleModel("gemini-3.6-flash"),
            messages: [Message(role: .user, content: [
                .text("Summarize this call."),
                .file(FileContent(url: uri, mediaType: "audio/mpeg"))
            ])]
        )
        print(answer.text)

        let cache = GoogleCachedContentClient()
        let name = try await cache.create(
            model: "gemini-3.5-flash", messages: transcript, ttlSeconds: 600
        )
        let cached = try await generateText(
            model: GoogleModel("gemini-3.5-flash"),
            prompt: "Summarize the transcript.",
            providerOptions: ["cachedContent": .string(name)]
        )
        print(cached.text)
        try await cache.delete(name)
    }

    static func batchAndTokens() async throws {
        let model = GoogleModel("gemini-3.6-flash")
        print(try await model.countTokens([.user("How many tokens is this?")]))

        let batches = GoogleBatchClient()
        let name = try await batches.create(
            model: "gemini-3.6-flash",
            displayName: "nightly",
            requests: [
                .init(key: "request-1", messages: [.user("Describe photosynthesis.")]),
                .init(key: "request-2", messages: [.user("Describe respiration.")])
            ]
        )
        print(try await batches.get(name))
    }

    static func media(prompt: String) async throws {
        let image = try await generateImage(
            model: GoogleImageModel("imagen-4.0-generate-001"), prompt: prompt, n: 2
        )
        print(image.images.count)

        let video = try await generateVideo(
            model: GoogleVideoModel("veo-3.1-generate-preview"),
            prompt: prompt,
            aspectRatio: "16:9"
        )
        print(video.video?.count ?? 0)

        let speech = try await generateSpeech(
            model: GoogleSpeechModel("gemini-3.1-flash-tts-preview"),
            text: "Ready when you are.",
            voice: "Kore"
        )
        print(speech.audio.count)

        let music = try await GoogleMusicModel("lyria-3-clip-preview")
            .generateMusic(prompt: "warm lofi beat, 90 bpm")
        print(music.count)
    }
}

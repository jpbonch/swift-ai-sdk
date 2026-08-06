import AI
import Foundation

extension XAIExamples {
    static func image() async throws {
        let result = try await generateImage(
            model: XaiImageModel("grok-2-image"),
            prompt: "A retro travel poster for Mars"
        )
        print(result.image.count)
    }

    static func speechAndTranscription() async throws {
        let spoken = try await generateSpeech(
            model: XaiSpeechModel("grok-tts"),
            text: "Welcome aboard.",
            voice: "eve"
        )
        print(spoken.mediaType)

        let audio = try exampleData(at: "/tmp/example.mp3")
        let text = try await transcribe(
            model: XaiTranscriptionModel("grok-stt"),
            audio: audio,
            mediaType: "audio/mpeg"
        )
        print(text.text)
    }

    static func deferredCompletion() async throws {
        let model = XaiModel.chat("grok-4.5")
        let done = try await model.submitDeferredCompletion(
            LanguageModelRequest(
                messages: [.user("Summarize the news in one line.")],
                maxOutputTokens: 128
            )
        )
        print(done.text, done.usage.outputTokens)
    }

    static func files() async throws {
        let files = XaiFilesClient()
        let uploaded = try await files.upload(
            Data("notes".utf8), filename: "notes.txt", mediaType: "text/plain",
            expiresAfter: 86_400
        )
        print(uploaded.id)

        let recent = try await files.list(limit: 20, order: "desc", filter: "name:notes")
        print(recent.count)
        try await files.delete(uploaded.id)
    }

    static func collections() async throws {
        let collections = XaiCollectionsClient()

        let id = try await collections.create(name: "Filings", description: "SEC filings")
        try await collections.addDocument(collectionID: id, fileID: "file_123")

        let documents = try await collections.listDocuments(collectionID: id, limit: 50)
        print(documents["documents"]?.arrayValue?.count ?? 0)

        let hits = try await collections.search(
            query: "revenue guidance",
            source: ["collection_ids": .array([.string(id)])]
        )
        print(hits)
    }

    static func modelCatalog() async throws {
        let models = XaiModelsClient()
        let language = try await models.languageModels()
        for model in language["models"]?.arrayValue ?? [] {
            print(
                model["id"]?.stringValue ?? "",
                model["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
        print(try await models.videoGenerationModels())
    }

    static func platform() async throws {
        let platform = XaiPlatformClient()
        print(try await platform.apiKeyInfo())

        let tokens = try await platform.tokenizeText("How many tokens?", model: "grok-4.5")
        print(tokens.count)

        print(try await platform.voices())
    }

    static func batches() async throws {
        let batches = XaiBatchClient()
        let request = XaiBatchClient.Request(
            id: "r1",
            model: "grok-4.5",
            body: ["messages": .array([["role": "user", "content": "hi"]])]
        )
        let batchID = try await batches.create(name: "nightly", requests: [request])
        try await batches.addRequests(batchID, requests: [request])
        print(try await batches.get(batchID))
        try await batches.cancel(batchID)
    }
}

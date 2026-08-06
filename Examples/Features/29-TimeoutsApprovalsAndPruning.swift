import AI
import Foundation

enum TimeoutApprovalAndPruningExamples {

    static let deleteFile = Tool(
        name: "deleteFile",
        description: "Delete a file.",
        parameters: [
            "type": "object",
            "properties": ["path": ["type": "string"]],
            "required": ["path"]
        ],
        inputExamples: [["path": "/tmp/cache.bin"]]
    ) { arguments in
        ["deleted": arguments["path"] ?? .null]
    }

    static func timeouts(model: any LanguageModel) async throws {
        let result = try await generateText(
            model: model,
            prompt: "Plan the migration.",
            tools: [deleteFile],
            timeout: GenerationTimeout(
                total: .seconds(60),
                step: .seconds(20),
                firstChunk: .seconds(5),
                chunk: .seconds(10),
                tool: .seconds(15),
                tools: ["deleteFile": .seconds(45)]
            )
        )
        print(result.text)
    }

    static func stallDetection(model: any LanguageModel) async {
        let result = streamText(
            model: model,
            prompt: "Write a long answer.",
            timeout: GenerationTimeout(firstChunk: .seconds(5), chunk: .seconds(10))
        )
        do {
            for try await delta in result.textStream { print(delta, terminator: "") }
        } catch let error as AIError {
            if case .timedOut(let scope, let limit, _) = error {
                print("stalled: \(scope.rawValue) exceeded \(limit)")
            }
        } catch {
            print("failed: \(error)")
        }
    }

    static func approvalPolicyMap(model: any LanguageModel) async throws {
        let result = try await generateText(
            model: model,
            prompt: "Clean up the temp files.",
            tools: [deleteFile],
            toolApproval: ["deleteFile": .userApproval(reason: "Destructive")]
        )
        for request in result.steps.flatMap(\.approvalRequests) {
            print("approve \(request.call.name)? signature=\(request.signature ?? "none")")
        }
    }

    static func approvalPolicyClosure(model: any LanguageModel) async throws {
        let policy = ToolApprovalPolicy { context in
            guard context.toolCall.name == "deleteFile" else { return .notApplicable }
            let path = context.toolCall.arguments["path"]?.stringValue ?? ""
            if path.hasPrefix("/etc") {
                return .denied(reason: "System paths are off limits")
            }
            let deletions = context.steps.flatMap(\.toolResults)
                .filter { $0.name == "deleteFile" }
            return deletions.count >= 3 ? .userApproval() : .approved()
        }

        let result = try await generateText(
            model: model, prompt: "Tidy up.", tools: [deleteFile], toolApproval: policy
        )
        print(result.steps.flatMap(\.approvalDecisions).count)
    }

    static func signedApprovals(model: any LanguageModel, messages: [Message]) async throws {
        let secret = ProcessInfo.processInfo.environment["TOOL_APPROVAL_SECRET"] ?? ""
        let result = try await generateText(
            model: model,
            messages: messages,
            tools: [deleteFile],
            toolApproval: ["deleteFile": .userApproval()],
            toolApprovalSecret: secret
        )
        print(result.text)
    }

    static func pruning(messages: [Message], uiMessages: [UIMessage]) {
        let trimmed = pruneMessages(
            messages, toolCalls: .beforeLastMessages(6, tools: ["search"])
        )
        let trimmedUI = pruneMessages(
            uiMessages, reasoning: .beforeLastMessage, toolCalls: .all
        )
        print(trimmed.count, trimmedUI.count)
    }

    static func middlewareStack(model: any LanguageModel) -> any LanguageModel {
        wrapLanguageModel(model: model, middleware: [
            .extractJson(),
            .addToolInputExamples(prefix: "Input Examples:"),
            .defaultSettings(temperature: 0.2)
        ])
    }

    static func wrappedEmbeddings(model: any EmbeddingModel) -> any EmbeddingModel {
        wrapEmbeddingModel(model: model, middleware: [.defaultSettings(maxBatchSize: 96)])
    }

    static func liveTranscription(chunks: AsyncThrowingStream<Data, Error>) async throws {
        let result = try streamTranscribe(
            model: DeepgramTranscriptionModel("nova-3"),
            audio: chunks,
            mediaType: "audio/pcm",
            providerOptions: ["language": "en-US"]
        )

        for try await part in result.fullStream {
            switch part {
            case .partialTranscript(let draft): print("… \(draft)")
            case .transcriptDelta(let text): print(text, terminator: "")
            case .finish(let response): print("\nfinal: \(response.text)")
            default: break
            }
        }
    }

    static func hostedTools() -> [any AIToolProtocol] {
        [
            OpenAIModel.Tools.imageGeneration(quality: "high", size: "1024x1024"),
            OpenAIModel.Tools.shell(),
            OpenAIModel.Tools.applyPatch(),
            OpenAIModel.Tools.toolSearch(execution: "server"),
            OpenAIModel.Tools.mcpServer(
                serverLabel: "docs", serverURL: "https://example.com/mcp"
            ),
            AnthropicModel.Tools.advisor(model: "claude-haiku-4-5", maxUses: 3),
            AnthropicModel.Tools.toolSearchBm25(),
            GoogleModel.Tools.vertexRagStore(
                ragCorpus: "projects/p/locations/l/ragCorpora/1", topK: 5
            )
        ]
    }

    static func uiHelpers(messages: [UIMessage]) throws {
        let validated = try validateUIMessages(messages)
        if lastAssistantMessageIsCompleteWithToolCalls(validated) {
            print("every tool call has a result")
        }
        if lastAssistantMessageIsCompleteWithApprovalResponses(validated) {
            print("every approval was answered")
        }
    }

    static func resampleMicrophoneAudio(_ pcm48k: Data) -> Data {
        resampleAudio(pcm48k, inputRate: 48_000, outputRate: 24_000)
    }
}

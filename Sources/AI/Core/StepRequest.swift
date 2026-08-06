import Foundation

/// Everything the generation loop needs to make one model call.
///
/// Assembling a step is a pipeline — ask `prepareStep` for overrides, inline
/// content the model cannot fetch, narrow and order the tools, resolve any
/// context-dependent descriptions — and none of it depends on what came back
/// from the previous call. Keeping it here leaves `runGenerationLoop` to do the
/// part that is genuinely a loop.
struct StepRequest {
    var model: any LanguageModel
    var tools: [any AIToolProtocol]
    var request: LanguageModelRequest

    /// Every provider rejects a request whose assistant turn asks for tools
    /// that were never answered, and it does so with an opaque 400. Catching it
    /// here names the tool calls that are missing results instead.
    ///
    /// A trailing assistant message with open calls is the normal pause — the
    /// run is waiting on the client or on an approval — so the check only fires
    /// once a user or system turn has moved the conversation past them.
    static func validateToolResults(in messages: [Message]) throws {
        var awaitingApproval: Set<String> = []
        for message in messages {
            for part in message.content {
                guard case .toolApprovalResponse(let response) = part else { continue }
                awaitingApproval.insert(response.toolCallID)
            }
        }

        var open: [String] = []
        for message in messages {
            switch message.role {
            case .assistant:
                for part in message.content {
                    guard case .toolCall(let call) = part, !call.providerExecuted else { continue }
                    open.append(call.id)
                }
            case .tool:
                for part in message.content {
                    guard case .toolResult(let result) = part else { continue }
                    open.removeAll { $0 == result.toolCallID }
                }
            case .user, .system:
                open.removeAll { awaitingApproval.contains($0) }
                guard open.isEmpty else { throw AIError.missingToolResults(open) }
            }
        }
    }

    /// `history` is `inout` so that downloaded attachments are written back
    /// once. Inlining into a per-step copy would re-fetch every URL on every
    /// step of the run.
    static func assemble(
        parameters: GenerationParameters,
        history: inout [Message],
        steps: [StepResult],
        stepIndex: Int,
        runtimeContext: inout JSONValue?
    ) async throws -> StepRequest {
        history = try await RemoteContent.inlineUnsupportedURLs(
            in: history, model: parameters.model
        )

        var model = parameters.model
        var messages = history
        var tools = parameters.tools

        if let prepare = parameters.prepareStep {
            let context = PrepareStepContext(
                stepNumber: stepIndex,
                steps: steps,
                messages: history,
                model: model,
                runtimeContext: runtimeContext,
                toolsContext: parameters.toolsContext
            )
            if let overrides = try await prepare(context) {
                if let override = overrides.model { model = override }
                if let override = overrides.messages { messages = override }
                if let override = overrides.tools { tools = override }
                if let override = overrides.runtimeContext { runtimeContext = override }
            }
        }

        // `prepareStep` can swap in its own messages or a different model, so
        // anything it introduced still has to be inlined for that model.
        messages = try await RemoteContent.inlineUnsupportedURLs(in: messages, model: model)

        try validateToolResults(in: messages)

        let visible = parameters.activeTools.map { active in
            tools.filter { active.contains($0.name) }
        } ?? tools

        let requestTools = applyToolOrder(visible, order: parameters.toolOrder)
            .map { tool -> any AIToolProtocol in
                let resolved = tool.description(context: parameters.toolsContext[tool.name])
                guard resolved != tool.description else { return tool }
                return tool.resolvingDescription(resolved)
            }

        return StepRequest(
            model: model,
            tools: tools,
            request: LanguageModelRequest(
                messages: messages,
                tools: requestTools,
                toolChoice: parameters.toolChoice,
                maxOutputTokens: parameters.maxOutputTokens,
                temperature: parameters.temperature,
                topP: parameters.topP,
                topK: parameters.topK,
                presencePenalty: parameters.presencePenalty,
                frequencyPenalty: parameters.frequencyPenalty,
                seed: parameters.seed,
                reasoning: parameters.reasoning,
                stopSequences: parameters.stopSequences,
                responseFormat: parameters.responseFormat,
                providerOptions: parameters.providerOptions
            )
        )
    }
}

import Foundation

public enum TextStreamPart: Sendable {
    case startStep(index: Int)
    case textDelta(String)
    case reasoningDelta(String)
    case toolInputStart(id: String, name: String)
    case toolInputDelta(id: String, partialJSON: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case toolApprovalRequest(ToolApprovalRequest)
    case source(Source)
    case providerMetadata(JSONValue)
    case finishStep(StepResult)
    case finish(finishReason: FinishReason, totalUsage: Usage)
}

public struct StreamTextResult: Sendable {
    public let fullStream: AsyncThrowingStream<TextStreamPart, Error>

    public var textStream: AsyncThrowingStream<String, Error> {
        let parts = fullStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await part in parts {
                        if case .textDelta(let t) = part { continuation.yield(t) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public func streamText(
    model: any LanguageModel,
    messages: [Message] = [],
    system: String? = nil,
    prompt: String? = nil,
    tools: [any AIToolProtocol] = [],
    toolChoice: ToolChoice = .auto,
    activeTools: [String]? = nil,
    toolOrder: [String]? = nil,
    toolsContext: [String: JSONValue] = [:],
    maxOutputTokens: Int = 1024,
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    presencePenalty: Double? = nil,
    frequencyPenalty: Double? = nil,
    seed: Int? = nil,
    reasoning: ReasoningEffort = .providerDefault,
    stopSequences: [String] = [],
    providerOptions: JSONValue? = nil,
    stopWhen: [StopCondition]? = nil,
    maxSteps: Int = 8,
    prepareCall: PrepareCall? = nil,
    prepareStep: PrepareStep? = nil,
    onStepFinish: OnStepFinish? = nil,
    onFinish: (@Sendable (GenerateTextResult) async -> Void)? = nil,
    onError: (@Sendable (Error) async -> Void)? = nil,
    onChunk: (@Sendable (TextStreamPart) -> Void)? = nil,
    onAbort: (@Sendable () async -> Void)? = nil,
    repairToolCall: (@Sendable (ToolCall, [any AIToolProtocol]) async throws -> ToolCall?)? = nil,
    maxRetries: Int = 2,
    toolApproval: ToolApprovalPolicy? = nil,
    toolApprovalSecret: String? = nil,
    timeout: GenerationTimeout? = nil,
    runtimeContext: JSONValue? = nil,
    telemetry: TelemetrySettings? = nil,
    compaction: Compaction? = nil
) -> StreamTextResult {
    let parameters = GenerationParameters(
        model: model,
        messages: assembleMessages(messages: messages, system: system, prompt: prompt),
        tools: tools,
        toolChoice: toolChoice,
        activeTools: activeTools,
        toolsContext: toolsContext,
        maxOutputTokens: maxOutputTokens,
        temperature: temperature,
        topP: topP,
        topK: topK,
        presencePenalty: presencePenalty,
        frequencyPenalty: frequencyPenalty,
        seed: seed,
        reasoning: reasoning,
        stopSequences: stopSequences,
        responseFormat: .text,
        providerOptions: providerOptions,
        stopConditions: stopWhen ?? [.stepCountIs(max(1, maxSteps))],
        toolOrder: toolOrder,
        prepareCall: prepareCall,
        prepareStep: prepareStep,
        onStepFinish: onStepFinish,
        repairToolCall: repairToolCall,
        maxRetries: maxRetries,
        toolApproval: toolApproval,
        toolApprovalSecret: toolApprovalSecret,
        timeout: timeout,
        runtimeContext: runtimeContext,
        telemetry: telemetry,
        compaction: compaction
    )

    let stream = AsyncThrowingStream<TextStreamPart, Error> { continuation in
        let task = Task {
            do {
                let outcome = try await AITelemetry.span(
                    "ai.streamText",
                    attributes: [
                        "ai.model.provider": .string(model.provider),
                        "ai.model.id": .string(model.modelID)
                    ].merging(
                        telemetry?.attributes(
                            runtimeContext: runtimeContext, toolsContext: toolsContext
                        ) ?? [:]
                    ) { _, new in new },
                    enabled: telemetry?.isEnabled ?? true,
                    endAttributes: { (outcome: GenerationOutcome) in
                        [
                            "ai.usage.inputTokens": .number(Double(outcome.totalUsage.inputTokens)),
                            "ai.usage.outputTokens": .number(Double(outcome.totalUsage.outputTokens)),
                            "ai.response.finishReason": .string(outcome.finishReason.rawValue)
                        ]
                    }
                ) {
                    try await withTimeout(timeout?.total, scope: .total) {
                        try await runGenerationLoop(parameters) { part in
                            onChunk?(part)
                            continuation.yield(part)
                        }
                    }
                }
                await onFinish?(GenerateTextResult(outcome: outcome))
                continuation.finish()
            } catch is CancellationError {
                await onAbort?()
                continuation.finish(throwing: CancellationError())
            } catch {
                await onError?(error)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return StreamTextResult(fullStream: stream)
}

struct GenerationParameters: Sendable {
    var model: any LanguageModel
    var messages: [Message]
    var tools: [any AIToolProtocol]
    var toolChoice: ToolChoice = .auto
    var activeTools: [String]? = nil
    var toolsContext: [String: JSONValue] = [:]
    var maxOutputTokens: Int
    var temperature: Double?
    var topP: Double?
    var topK: Int? = nil
    var presencePenalty: Double? = nil
    var frequencyPenalty: Double? = nil
    var seed: Int? = nil
    var reasoning: ReasoningEffort = .providerDefault
    var stopSequences: [String]
    var responseFormat: ResponseFormat
    var providerOptions: JSONValue?
    var stopConditions: [StopCondition]
    var toolOrder: [String]? = nil
    var prepareCall: PrepareCall? = nil
    var prepareStep: PrepareStep?
    var onStepFinish: OnStepFinish?
    var repairToolCall: (@Sendable (ToolCall, [any AIToolProtocol]) async throws -> ToolCall?)? = nil
    var maxRetries: Int
    var toolApproval: ToolApprovalPolicy? = nil
    var toolApprovalSecret: String? = nil
    var timeout: GenerationTimeout? = nil
    var runtimeContext: JSONValue? = nil
    var telemetry: TelemetrySettings? = nil
    var compaction: Compaction? = nil
}

func applyToolOrder(
    _ tools: [any AIToolProtocol], order: [String]?
) -> [any AIToolProtocol] {
    guard let order, !order.isEmpty else { return tools }
    let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var ordered: [any AIToolProtocol] = []
    var used = Set<String>()
    for name in order where used.insert(name).inserted {
        if let tool = byName[name] { ordered.append(tool) }
    }
    ordered.append(contentsOf: tools.filter { !used.contains($0.name) }.sorted { $0.name < $1.name })
    return ordered
}

struct GenerationOutcome: Sendable {
    var steps: [StepResult]
    var messages: [Message]
    var finishReason: FinishReason
    var totalUsage: Usage
}

func assembleMessages(messages: [Message], system: String?, prompt: String?) -> [Message] {
    var out: [Message] = []
    if let system { out.append(.system(system)) }
    out.append(contentsOf: messages)
    if let prompt { out.append(.user(prompt)) }
    return out
}

func runGenerationLoop(
    _ parameters: GenerationParameters,
    emit: @Sendable (TextStreamPart) -> Void
) async throws -> GenerationOutcome {
    var parameters = parameters
    if let prepareCall = parameters.prepareCall {
        let context = PrepareCallContext(
            messages: parameters.messages, model: parameters.model, tools: parameters.tools
        )
        if let overrides = try await prepareCall(context) {
            if let model = overrides.model { parameters.model = model }
            if let messages = overrides.messages { parameters.messages = messages }
            if let tools = overrides.tools { parameters.tools = tools }
            if let toolChoice = overrides.toolChoice { parameters.toolChoice = toolChoice }
            if let activeTools = overrides.activeTools { parameters.activeTools = activeTools }
            if let toolOrder = overrides.toolOrder { parameters.toolOrder = toolOrder }
            if let maxOutputTokens = overrides.maxOutputTokens {
                parameters.maxOutputTokens = maxOutputTokens
            }
            if let temperature = overrides.temperature { parameters.temperature = temperature }
            if let topP = overrides.topP { parameters.topP = topP }
            if let topK = overrides.topK { parameters.topK = topK }
            if let reasoning = overrides.reasoning { parameters.reasoning = reasoning }
            if let providerOptions = overrides.providerOptions {
                parameters.providerOptions = providerOptions
            }
            if let toolApproval = overrides.toolApproval { parameters.toolApproval = toolApproval }
        }
    }

    var history = parameters.messages
    var steps: [StepResult] = []
    var totalUsage = Usage()
    var finalReason: FinishReason = .stop
    var stepIndex = 0
    var runtimeContext = parameters.runtimeContext
    var compactedContext: CompactedContext?

    var resumedResults = try await resolvePendingApprovals(
        in: &history,
        tools: parameters.tools,
        toolsContext: parameters.toolsContext,
        policy: parameters.toolApproval,
        secret: parameters.toolApprovalSecret,
        timeout: parameters.timeout
    )
    for result in resumedResults { emit(.toolResult(result)) }

    while true {
        if let compaction = parameters.compaction,
           let outcome = try await ContextCompactor.compact(
               history,
               settings: compaction,
               model: parameters.model,
               tools: parameters.tools,
               existing: compactedContext
           ) {
            history = outcome.messages
            compactedContext = outcome.event.context
        }

        let plan = try await StepRequest.assemble(
            parameters: parameters,
            history: &history,
            steps: steps,
            stepIndex: stepIndex,
            runtimeContext: &runtimeContext
        )
        let stepModel = plan.model
        let stepTools = plan.tools
        let stepMessages = plan.request.messages

        emit(.startStep(index: stepIndex))

        let request = plan.request

        let resolvedModel = stepModel
        let rawStream = try await Retry.withRetries(parameters.maxRetries) {
            try await resolvedModel.stream(request)
        }
        let stream = StreamTimeout.guarded(rawStream, timeout: parameters.timeout)

        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var providerCalls: [ToolCall] = []
        var providerResults: [ToolResult] = []
        var sources: [Source] = []
        var stepMetadata: JSONValue?
        var stepFinish: FinishReason = .stop
        var stepUsage = Usage()

        for try await part in stream {
            switch part {
            case .textDelta(let t):
                text += t
                emit(.textDelta(t))
            case .reasoningDelta(let t):
                reasoning += t
                emit(.reasoningDelta(t))
            case .toolCallStart(let id, let name):
                emit(.toolInputStart(id: id, name: name))
            case .toolArgumentsDelta(let id, let partialJSON):
                emit(.toolInputDelta(id: id, partialJSON: partialJSON))
            case .toolCall(let raw):
                var call = raw
                if let tool = stepTools.first(where: { $0.name == call.name }), tool.isDynamic {
                    call.isDynamic = true
                }
                if call.providerExecuted {
                    providerCalls.append(call)
                } else {
                    calls.append(call)
                }
                emit(.toolCall(call))
            case .toolResult(let result):
                providerResults.append(result)
                emit(.toolResult(result))
            case .source(let source):
                sources.append(source)
                emit(.source(source))
            case .providerMetadata(let meta):
                stepMetadata = JSONValue.mergingMetadata(stepMetadata, meta)
                emit(.providerMetadata(meta))
            case .finish(let reason, let usage):
                stepFinish = reason
                stepUsage = usage
            }
        }

        totalUsage = totalUsage + stepUsage

        var assistantParts: [ContentPart] = []
        if !text.isEmpty { assistantParts.append(.text(text)) }
        assistantParts.append(contentsOf: calls.map { .toolCall($0) })
        if !assistantParts.isEmpty {
            history.append(Message(role: .assistant, content: assistantParts))
        }

        var results: [ToolResult] = []
        var approvalRequests: [ToolApprovalRequest] = []
        var approvalDecisions: [String: ToolApprovalDecision] = [:]
        var hasClientSideCalls = false
        if !calls.isEmpty {
            let toolIndex = Dictionary(
                stepTools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }
            )
            var executable: [ToolCall] = []
            var denials: [ToolResult] = []
            for original in calls {
                var call = original
                var repairFailure: Error?

                func repairing(_ reason: Error) async -> Bool {
                    guard let repair = parameters.repairToolCall else { return false }
                    do {
                        guard let repaired = try await repair(call, stepTools) else { return false }
                        call = repaired
                        return true
                    } catch {
                        repairFailure = AIError.toolCallRepairFailed(
                            tool: call.name, reason: "\(error) (repairing: \(reason))"
                        )
                        return false
                    }
                }

                let unknownTool = AIError.invalidToolInput(
                    tool: call.name, reason: "no tool named '\(call.name)' is available"
                )
                if toolIndex[call.name] == nil {
                    _ = await repairing(unknownTool)
                }

                // Arguments arrive as whatever the model emitted. Giving repair
                // a shot before reporting mirrors how the SDK treats a schema
                // mismatch: recoverable first, an error on the call second.
                if repairFailure == nil, let tool = toolIndex[call.name],
                   let mismatch = validationError(call.arguments, against: tool) {
                    _ = await repairing(mismatch)
                    if repairFailure == nil {
                        if let repaired = toolIndex[call.name],
                           let remaining = validationError(call.arguments, against: repaired) {
                            repairFailure = AIError.invalidToolInput(
                                tool: call.name, reason: "\(remaining)"
                            )
                        } else if toolIndex[call.name] == nil {
                            repairFailure = unknownTool
                        }
                    }
                }

                if let failure = repairFailure {
                    denials.append(ToolResult(
                        toolCallID: call.id, name: call.name,
                        output: .string("Error: \(failure)"), isError: true
                    ))
                    continue
                }

                guard let tool = toolIndex[call.name] else {
                    executable.append(call)
                    continue
                }
                guard tool.hasExecutor else {
                    hasClientSideCalls = true
                    continue
                }

                var decision = ToolApprovalDecision.notApplicable
                var fromPolicy = false
                if let policy = parameters.toolApproval {
                    decision = await policy.decide(ToolApprovalContext(
                        toolCall: call,
                        tool: tool,
                        messages: stepMessages,
                        stepNumber: stepIndex,
                        steps: steps
                    ))
                    if case .notApplicable = decision {} else { fromPolicy = true }
                }
                if case .notApplicable = decision, await tool.needsApproval(call.arguments) {
                    decision = .userApproval()
                }
                if case .notApplicable = decision {} else {
                    approvalDecisions[call.id] = decision
                }

                switch decision {
                case .notApplicable, .approved:
                    executable.append(call)
                case .denied(let reason):
                    denials.append(ToolResult(
                        toolCallID: call.id,
                        name: call.name,
                        output: .string(reason ?? "Tool execution denied."),
                        denied: true
                    ))
                case .userApproval(let reason):
                    let approvalID = "approval-\(call.id)"
                    let request = ToolApprovalRequest(
                        approvalID: approvalID,
                        call: call,
                        reason: reason,
                        isAutomatic: fromPolicy,
                        signature: parameters.toolApprovalSecret.flatMap {
                            ToolApprovalSignature.sign(
                                secret: $0, approvalID: approvalID,
                                toolName: call.name, toolCallID: call.id, input: call.arguments
                            )
                        }
                    )
                    approvalRequests.append(request)
                    emit(.toolApprovalRequest(request))
                }
            }
            results = denials + (await executeToolCalls(
                executable, using: toolIndex,
                messages: stepMessages, toolsContext: parameters.toolsContext,
                timeout: parameters.timeout
            ))
            try Task.checkCancellation()
            for result in results { emit(.toolResult(result)) }
            if !results.isEmpty {
                history.append(Message(role: .tool, content: results.map { .toolResult($0) }))
            }
        }

        let step = StepResult(
            text: text,
            reasoningText: reasoning,
            toolCalls: providerCalls + calls,
            toolResults: resumedResults + providerResults + results,
            sources: sources,
            approvalRequests: approvalRequests,
            approvalDecisions: approvalDecisions,
            runtimeContext: runtimeContext,
            providerMetadata: stepMetadata,
            finishReason: stepFinish,
            usage: stepUsage
        )
        steps.append(step)
        resumedResults = []
        emit(.finishStep(step))
        await parameters.onStepFinish?(step)

        if calls.isEmpty {
            finalReason = stepFinish
            break
        }
        if hasClientSideCalls || !approvalRequests.isEmpty {
            finalReason = .toolCalls
            break
        }
        if parameters.stopConditions.anyMet(steps) {
            finalReason = .toolCalls
            break
        }
        stepIndex += 1
    }

    emit(.finish(finishReason: finalReason, totalUsage: totalUsage))
    return GenerationOutcome(
        steps: steps, messages: history, finishReason: finalReason, totalUsage: totalUsage
    )
}

func resolvePendingApprovals(
    in history: inout [Message],
    tools: [any AIToolProtocol],
    toolsContext: [String: JSONValue] = [:],
    policy: ToolApprovalPolicy? = nil,
    secret: String? = nil,
    timeout: GenerationTimeout? = nil
) async throws -> [ToolResult] {
    guard let assistantIndex = history.lastIndex(where: { $0.role == .assistant }) else {
        return []
    }
    let pendingCalls = history[assistantIndex].content.compactMap { part -> ToolCall? in
        if case .toolCall(let call) = part { return call }
        return nil
    }
    guard !pendingCalls.isEmpty else { return [] }

    var responses: [String: ToolApprovalResponse] = [:]
    var resolvedIDs = Set<String>()
    for message in history[(assistantIndex + 1)...] {
        for part in message.content {
            switch part {
            case .toolApprovalResponse(let response):
                responses[response.toolCallID] = response
            case .toolResult(let result):
                resolvedIDs.insert(result.toolCallID)
            default:
                break
            }
        }
    }
    let decided = pendingCalls.filter {
        responses[$0.id] != nil && !resolvedIDs.contains($0.id)
    }
    guard !decided.isEmpty else { return [] }

    let toolIndex = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var results: [ToolResult] = []
    var approved: [ToolCall] = []
    for call in decided {
        guard let response = responses[call.id] else { continue }
        if let secret, !secret.isEmpty {
            // Denying every call one by one would look like a signing bug in
            // the client rather than a missing platform capability.
            guard ToolApprovalSignature.isSupported else {
                throw AIError.unsupportedFunctionality(
                    "toolApprovalSecret needs CryptoKit to sign and verify approvals, "
                    + "which this platform does not provide. Drop the secret to use "
                    + "unsigned approvals, or run where CryptoKit is available."
                )
            }
            let valid = ToolApprovalSignature.verify(
                response.signature,
                secret: secret,
                approvalID: response.approvalID,
                toolName: call.name,
                toolCallID: call.id,
                input: call.arguments
            )
            guard valid else {
                throw AIError.invalidToolApproval(
                    "the response for '\(call.name)' (\(response.approvalID)) carries no valid "
                    + "signature, so it did not come from this server"
                )
            }
        }
        guard response.approved else {
            results.append(ToolResult(
                toolCallID: call.id, name: call.name,
                output: .string(response.reason ?? "Tool execution denied."),
                denied: true
            ))
            continue
        }

        // Everything above this point came out of client-supplied history, so
        // the arguments and the policy both have to be checked again. An
        // approval recorded in an earlier turn is not permission to run
        // whatever the client has since edited the call into.
        if let tool = toolIndex[call.name] {
            do {
                try Schema.raw(tool.parameters).validate(call.arguments)
            } catch {
                throw AIError.invalidToolInput(tool: call.name, reason: "\(error)")
            }
        }

        var decision = ToolApprovalDecision.notApplicable
        if let policy {
            decision = await policy.decide(ToolApprovalContext(
                toolCall: call,
                tool: toolIndex[call.name],
                messages: history,
                stepNumber: 0,
                steps: []
            ))
        }
        if case .denied(let reason) = decision {
            results.append(ToolResult(
                toolCallID: call.id, name: call.name,
                output: .string(reason ?? response.reason ?? "Tool execution denied."),
                denied: true
            ))
            continue
        }
        approved.append(call)
    }
    results.append(contentsOf: await executeToolCalls(
        approved, using: toolIndex, messages: history,
        toolsContext: toolsContext, timeout: timeout
    ))

    history = history.map { message in
        var message = message
        message.content.removeAll {
            if case .toolApprovalResponse = $0 { return true }
            return false
        }
        return message
    }.filter { !$0.content.isEmpty }
    history.append(Message(role: .tool, content: results.map { .toolResult($0) }))
    return results
}

/// Provider-defined tools carry a declaration rather than a schema the caller
/// owns, so only tools this SDK will actually execute are checked.
func validationError(_ arguments: JSONValue, against tool: any AIToolProtocol) -> Error? {
    guard tool.hasExecutor, case .object = tool.parameters else { return nil }
    do {
        try Schema.raw(tool.parameters).validate(arguments)
        return nil
    } catch {
        return error
    }
}

func executeToolCalls(
    _ calls: [ToolCall],
    using index: [String: any AIToolProtocol],
    messages: [Message] = [],
    toolsContext: [String: JSONValue] = [:],
    timeout: GenerationTimeout? = nil
) async -> [ToolResult] {
    await withTaskGroup(of: (Int, ToolResult).self) { group in
        for (order, call) in calls.enumerated() {
            group.addTask {
                guard let tool = index[call.name] else {
                    return (order, ToolResult(
                        toolCallID: call.id, name: call.name,
                        output: .string("Error: unknown tool '\(call.name)'"),
                        isError: true
                    ))
                }
                do {
                    let context = toolsContext[call.name]
                    try tool.validateContext(context)
                    let options = ToolExecutionOptions(
                        toolCallID: call.id,
                        messages: messages,
                        context: context
                    )
                    let output = try await withTimeout(
                        timeout?.limit(forTool: call.name), scope: .tool, tool: call.name
                    ) {
                        try await tool.execute(call.arguments, options: options)
                    }
                    return (order, ToolResult(
                        toolCallID: call.id, name: call.name, output: output,
                        content: tool.toModelOutput(output)
                    ))
                } catch is CancellationError {
                    return (order, ToolResult(
                        toolCallID: call.id, name: call.name,
                        output: .string("Error: tool execution was cancelled"), isError: true
                    ))
                } catch {
                    return (order, ToolResult(
                        toolCallID: call.id, name: call.name,
                        output: .string("Error: \(error)"), isError: true
                    ))
                }
            }
        }
        var indexed: [(Int, ToolResult)] = []
        for await pair in group { indexed.append(pair) }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

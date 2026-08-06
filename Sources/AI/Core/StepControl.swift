import Foundation

public struct ToolApprovalRequest: Sendable, Hashable {
    public var approvalID: String
    public var call: ToolCall
    public var reason: String?
    /// True when an approval policy asked for the confirmation, false when the
    /// tool declared `needsApproval` itself.
    public var isAutomatic: Bool?
    public var signature: String?

    public init(
        approvalID: String,
        call: ToolCall,
        reason: String? = nil,
        isAutomatic: Bool? = nil,
        signature: String? = nil
    ) {
        self.approvalID = approvalID
        self.call = call
        self.reason = reason
        self.isAutomatic = isAutomatic
        self.signature = signature
    }
}

public struct StepResult: Sendable {
    public var text: String
    public var reasoningText: String
    public var toolCalls: [ToolCall]
    public var toolResults: [ToolResult]
    public var sources: [Source]
    public var approvalRequests: [ToolApprovalRequest]
    public var approvalDecisions: [String: ToolApprovalDecision]
    public var runtimeContext: JSONValue?
    public var providerMetadata: JSONValue?
    public var finishReason: FinishReason
    public var usage: Usage

    public init(
        text: String = "",
        reasoningText: String = "",
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        sources: [Source] = [],
        approvalRequests: [ToolApprovalRequest] = [],
        approvalDecisions: [String: ToolApprovalDecision] = [:],
        runtimeContext: JSONValue? = nil,
        providerMetadata: JSONValue? = nil,
        finishReason: FinishReason = .stop,
        usage: Usage = Usage()
    ) {
        self.approvalDecisions = approvalDecisions
        self.runtimeContext = runtimeContext
        self.text = text
        self.reasoningText = reasoningText
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.sources = sources
        self.approvalRequests = approvalRequests
        self.providerMetadata = providerMetadata
        self.finishReason = finishReason
        self.usage = usage
    }
}

public struct StopCondition: Sendable {
    private let predicate: @Sendable ([StepResult]) -> Bool

    public init(_ predicate: @escaping @Sendable ([StepResult]) -> Bool) {
        self.predicate = predicate
    }

    public func isMet(_ steps: [StepResult]) -> Bool { predicate(steps) }

    public static func isStepCount(_ count: Int) -> StopCondition {
        StopCondition { $0.count >= count }
    }

    public static func stepCountIs(_ count: Int) -> StopCondition {
        isStepCount(count)
    }

    public static func isLoopFinished() -> StopCondition {
        StopCondition { _ in false }
    }

    public static func hasToolCall(_ toolNames: String...) -> StopCondition {
        hasToolCall(toolNames)
    }

    public static func hasToolCall(_ toolNames: [String]) -> StopCondition {
        StopCondition { steps in
            steps.last?.toolCalls.contains { toolNames.contains($0.name) } ?? false
        }
    }
}

public func isStepCount(_ count: Int) -> StopCondition { .isStepCount(count) }
public func isLoopFinished() -> StopCondition { .isLoopFinished() }
public func stepCountIs(_ count: Int) -> StopCondition { .isStepCount(count) }
public func hasToolCall(_ toolNames: String...) -> StopCondition { .hasToolCall(toolNames) }

extension Sequence where Element == StopCondition {
    func anyMet(_ steps: [StepResult]) -> Bool {
        contains { $0.isMet(steps) }
    }
}

public struct PrepareStepContext: Sendable {
    public var stepNumber: Int
    public var steps: [StepResult]
    public var messages: [Message]
    public var model: any LanguageModel
    public var runtimeContext: JSONValue?
    public var toolsContext: [String: JSONValue]

    public init(
        stepNumber: Int,
        steps: [StepResult],
        messages: [Message],
        model: any LanguageModel,
        runtimeContext: JSONValue? = nil,
        toolsContext: [String: JSONValue] = [:]
    ) {
        self.stepNumber = stepNumber
        self.steps = steps
        self.messages = messages
        self.model = model
        self.runtimeContext = runtimeContext
        self.toolsContext = toolsContext
    }
}

public struct PrepareStepResult: Sendable {
    public var model: (any LanguageModel)?
    public var messages: [Message]?
    public var tools: [any AIToolProtocol]?
    public var runtimeContext: JSONValue?

    public init(
        model: (any LanguageModel)? = nil,
        messages: [Message]? = nil,
        tools: [any AIToolProtocol]? = nil,
        runtimeContext: JSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.runtimeContext = runtimeContext
    }
}

public typealias PrepareStep = @Sendable (PrepareStepContext) async throws -> PrepareStepResult?

public struct PrepareCallContext: Sendable {
    public var messages: [Message]
    public var model: any LanguageModel
    public var tools: [any AIToolProtocol]

    public init(messages: [Message], model: any LanguageModel, tools: [any AIToolProtocol]) {
        self.messages = messages
        self.model = model
        self.tools = tools
    }
}

public struct PrepareCallResult: Sendable {
    public var model: (any LanguageModel)?
    public var messages: [Message]?
    public var tools: [any AIToolProtocol]?
    public var toolChoice: ToolChoice?
    public var activeTools: [String]?
    public var toolOrder: [String]?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var reasoning: ReasoningEffort?
    public var providerOptions: JSONValue?
    public var toolApproval: ToolApprovalPolicy?

    public init(
        model: (any LanguageModel)? = nil,
        messages: [Message]? = nil,
        tools: [any AIToolProtocol]? = nil,
        toolChoice: ToolChoice? = nil,
        activeTools: [String]? = nil,
        toolOrder: [String]? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        reasoning: ReasoningEffort? = nil,
        providerOptions: JSONValue? = nil,
        toolApproval: ToolApprovalPolicy? = nil
    ) {
        self.toolApproval = toolApproval
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.activeTools = activeTools
        self.toolOrder = toolOrder
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.reasoning = reasoning
        self.providerOptions = providerOptions
    }
}

public typealias PrepareCall = @Sendable (PrepareCallContext) async throws -> PrepareCallResult?

public typealias OnStepFinish = @Sendable (StepResult) async -> Void

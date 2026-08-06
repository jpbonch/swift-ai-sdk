import Foundation

public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var providerExecuted: Bool
    public var isDynamic: Bool

    public init(
        id: String,
        name: String,
        arguments: JSONValue,
        providerExecuted: Bool = false,
        isDynamic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerExecuted = providerExecuted
        self.isDynamic = isDynamic
    }
}

public struct ToolResult: Sendable, Hashable {
    public var toolCallID: String
    public var name: String
    public var output: JSONValue
    public var content: [ContentPart]?
    public var isError: Bool
    public var denied: Bool

    public init(
        toolCallID: String, name: String, output: JSONValue,
        content: [ContentPart]? = nil,
        isError: Bool = false, denied: Bool = false
    ) {
        self.toolCallID = toolCallID
        self.name = name
        self.output = output
        self.content = content
        self.isError = isError
        self.denied = denied
    }
}

public struct ToolLoading: Sendable, Hashable {
    public var strict: Bool?
    public var deferLoading: Bool?
    public var allowedCallers: [String]?
    public var cacheControl: JSONValue?
    public var eagerInputStreaming: Bool?

    public init(
        strict: Bool? = nil,
        deferLoading: Bool? = nil,
        allowedCallers: [String]? = nil,
        cacheControl: JSONValue? = nil,
        eagerInputStreaming: Bool? = nil
    ) {
        self.strict = strict
        self.deferLoading = deferLoading
        self.allowedCallers = allowedCallers
        self.cacheControl = cacheControl
        self.eagerInputStreaming = eagerInputStreaming
    }

    public static let none = ToolLoading()

    public var isEmpty: Bool { self == .none }

    public static func ephemeralCache() -> ToolLoading {
        ToolLoading(cacheControl: .object(["type": .string("ephemeral")]))
    }

    public static func codeExecutionOnly(
        version: String = "code_execution_20260120"
    ) -> ToolLoading {
        ToolLoading(allowedCallers: [version])
    }
}

public protocol AIToolProtocol: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    var inputExamples: [JSONValue] { get }
    var contextSchema: Schema? { get }
    var isDynamic: Bool { get }
    var isIdempotent: Bool { get }
    var loading: ToolLoading { get }
    var hasExecutor: Bool { get }
    func description(context: JSONValue?) -> String
    func resolvingDescription(_ description: String) -> any AIToolProtocol
    func needsApproval(_ arguments: JSONValue) async -> Bool
    func execute(_ arguments: JSONValue) async throws -> JSONValue
    func execute(_ arguments: JSONValue, options: ToolExecutionOptions) async throws -> JSONValue
    func toModelOutput(_ output: JSONValue) -> [ContentPart]?
}

public struct ToolExecutionOptions: Sendable {
    public var toolCallID: String
    public var messages: [Message]
    public var context: JSONValue?

    public init(toolCallID: String, messages: [Message] = [], context: JSONValue? = nil) {
        self.toolCallID = toolCallID
        self.messages = messages
        self.context = context
    }
}

public extension AIToolProtocol {
    var inputExamples: [JSONValue] { [] }
    var contextSchema: Schema? { nil }
    var isDynamic: Bool { false }
    var isIdempotent: Bool { false }
    var loading: ToolLoading { .none }
    var hasExecutor: Bool { true }

    func description(context: JSONValue?) -> String { description }

    // Conforming types that can carry a description return a copy with it
    // replaced. A wrapper type would have to forward every other member by
    // hand, and would silently drop whichever ones it forgot.
    func resolvingDescription(_ description: String) -> any AIToolProtocol { self }

    func validateContext(_ context: JSONValue?) throws {
        guard let contextSchema else { return }
        do {
            try contextSchema.validate(context ?? .null)
        } catch {
            throw AIError.invalidToolContext(tool: name, reason: "\(error)")
        }
    }
    func needsApproval(_ arguments: JSONValue) async -> Bool { false }
    func execute(
        _ arguments: JSONValue, options: ToolExecutionOptions
    ) async throws -> JSONValue {
        try await execute(arguments)
    }
    func toModelOutput(_ output: JSONValue) -> [ContentPart]? { nil }
}

public struct Tool: AIToolProtocol {
    public let name: String
    public var description: String
    public let parameters: JSONValue
    public var inputExamples: [JSONValue] = []
    public var contextSchema: Schema?
    public var isDynamic: Bool = false
    public var isIdempotent: Bool = false
    public var loading: ToolLoading = .none
    public var describeWithContext: (@Sendable (JSONValue?) -> String)?
    private let run: (@Sendable (JSONValue) async throws -> JSONValue)?
    private let contextualRun: (@Sendable (JSONValue, ToolExecutionOptions) async throws -> JSONValue)?
    private let approvalCheck: (@Sendable (JSONValue) async -> Bool)?
    public var modelOutput: (@Sendable (JSONValue) -> [ContentPart]?)? = nil

    public var hasExecutor: Bool { run != nil || contextualRun != nil }

    public func toModelOutput(_ output: JSONValue) -> [ContentPart]? {
        if let modelOutput { return modelOutput(output) }
        return nil
    }

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        inputExamples: [JSONValue] = [],
        needsApproval: Bool = false,
        execute: @escaping @Sendable (JSONValue, ToolExecutionOptions) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.inputExamples = inputExamples
        self.run = nil
        self.contextualRun = execute
        self.approvalCheck = needsApproval ? { @Sendable _ in true } : nil
    }

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        inputExamples: [JSONValue] = [],
        needsApproval: Bool = false,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.inputExamples = inputExamples
        self.run = execute
        self.contextualRun = nil
        self.approvalCheck = needsApproval ? { @Sendable _ in true } : nil
    }

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        inputExamples: [JSONValue] = [],
        needsApproval: @escaping @Sendable (JSONValue) async -> Bool,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.inputExamples = inputExamples
        self.run = execute
        self.contextualRun = nil
        self.approvalCheck = needsApproval
    }

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        inputExamples: [JSONValue] = []
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.inputExamples = inputExamples
        self.run = nil
        self.contextualRun = nil
        self.approvalCheck = nil
    }

    public func needsApproval(_ arguments: JSONValue) async -> Bool {
        await approvalCheck?(arguments) ?? false
    }

    public func description(context: JSONValue?) -> String {
        describeWithContext?(context) ?? description
    }

    public func resolvingDescription(_ description: String) -> any AIToolProtocol {
        var copy = self
        copy.description = description
        // The description is now fixed, so the closure that produced it would
        // only be able to disagree with it.
        copy.describeWithContext = nil
        // Whoever rewrote the description is the one inlining the examples;
        // leaving them set would send them again as a native field.
        copy.inputExamples = []
        return copy
    }

    public func execute(_ arguments: JSONValue) async throws -> JSONValue {
        try await execute(arguments, options: ToolExecutionOptions(toolCallID: ""))
    }

    public func execute(
        _ arguments: JSONValue, options: ToolExecutionOptions
    ) async throws -> JSONValue {
        if let contextualRun { return try await contextualRun(arguments, options) }
        guard let run else { throw AIError.unknownTool(name) }
        return try await run(arguments)
    }
}

public extension Tool {
    static func dynamic(
        name: String,
        description: String,
        parameters: JSONValue = .object(["type": .string("object")]),
        execute: @escaping @Sendable (JSONValue, ToolExecutionOptions) async throws -> JSONValue
    ) -> Tool {
        var tool = Tool(
            name: name, description: description, parameters: parameters, execute: execute
        )
        tool.isDynamic = true
        return tool
    }

    func withContextSchema(_ schema: Schema) -> Tool {
        var copy = self
        copy.contextSchema = schema
        return copy
    }

    func idempotent(_ isIdempotent: Bool = true) -> Tool {
        var copy = self
        copy.isIdempotent = isIdempotent
        return copy
    }

    func describing(_ describe: @escaping @Sendable (JSONValue?) -> String) -> Tool {
        var copy = self
        copy.describeWithContext = describe
        return copy
    }

    func loading(_ loading: ToolLoading) -> Tool {
        var copy = self
        copy.loading = loading
        return copy
    }

    static func typed<Args: Decodable & Sendable>(
        name: String,
        description: String,
        parameters: JSONValue,
        argumentsType: Args.Type = Args.self,
        execute: @escaping @Sendable (Args) async throws -> JSONValue
    ) -> Tool {
        Tool(name: name, description: description, parameters: parameters) { raw in
            let args = try raw.decode(Args.self)
            return try await execute(args)
        }
    }
}

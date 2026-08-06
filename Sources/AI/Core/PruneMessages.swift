import Foundation

public enum PruneScope: Sendable, Hashable {
    case all
    case beforeLastMessage
    case beforeLastMessages(Int)
    case none

    func cutoff(messageCount: Int) -> Int {
        switch self {
        case .all: messageCount
        case .beforeLastMessage: max(messageCount - 1, 0)
        case .beforeLastMessages(let count): max(messageCount - max(count, 0), 0)
        case .none: 0
        }
    }
}

public struct PruneToolCalls: Sendable, Hashable {
    public var scope: PruneScope
    public var tools: [String]?

    public init(scope: PruneScope, tools: [String]? = nil) {
        self.scope = scope
        self.tools = tools
    }

    public static let none = PruneToolCalls(scope: .none)
    public static let all = PruneToolCalls(scope: .all)
    public static let beforeLastMessage = PruneToolCalls(scope: .beforeLastMessage)

    public static func beforeLastMessages(_ count: Int, tools: [String]? = nil) -> PruneToolCalls {
        PruneToolCalls(scope: .beforeLastMessages(count), tools: tools)
    }

    func matches(_ name: String) -> Bool {
        guard let tools else { return true }
        return tools.contains(name)
    }
}

public enum PruneEmptyMessages: Sendable, Hashable {
    case keep
    case remove
}

public func pruneMessages(
    _ messages: [Message],
    toolCalls: [PruneToolCalls] = [],
    emptyMessages: PruneEmptyMessages = .remove
) -> [Message] {
    var pruned = messages

    // Each rule is applied over the whole transcript in turn, and a rule only
    // ever removes a tool call whose id is absent from its own keep window.
    // Deciding by message index alone would drop a call whose result the caller
    // explicitly asked to keep, taking the result down with it.
    for rule in toolCalls {
        let cutoff = rule.scope.cutoff(messageCount: pruned.count)
        var keptToolCallIDs = Set<String>()
        for message in pruned[cutoff...] {
            for part in message.content {
                switch part {
                case .toolCall(let call): keptToolCallIDs.insert(call.id)
                case .toolResult(let result): keptToolCallIDs.insert(result.toolCallID)
                case .toolApprovalResponse(let response):
                    keptToolCallIDs.insert(response.toolCallID)
                default: continue
                }
            }
        }

        var dropped = Set<String>()
        for index in pruned.indices where index < cutoff {
            pruned[index].content.removeAll { part in
                guard case .toolCall(let call) = part else { return false }
                guard !keptToolCallIDs.contains(call.id), rule.matches(call.name) else {
                    return false
                }
                dropped.insert(call.id)
                return true
            }
        }

        guard !dropped.isEmpty else { continue }
        for index in pruned.indices {
            pruned[index].content.removeAll { part in
                switch part {
                case .toolResult(let result): dropped.contains(result.toolCallID)
                case .toolApprovalResponse(let response): dropped.contains(response.toolCallID)
                default: false
                }
            }
        }
    }

    guard emptyMessages == .remove else { return pruned }
    return pruned.filter { !$0.content.isEmpty }
}

public func pruneMessages(
    _ messages: [Message],
    toolCalls: PruneToolCalls,
    emptyMessages: PruneEmptyMessages = .remove
) -> [Message] {
    pruneMessages(messages, toolCalls: [toolCalls], emptyMessages: emptyMessages)
}

public func pruneMessages(
    _ messages: [UIMessage],
    reasoning: PruneScope = .none,
    toolCalls: [PruneToolCalls] = [],
    emptyMessages: PruneEmptyMessages = .remove
) -> [UIMessage] {
    let reasoningCutoff = reasoning.cutoff(messageCount: messages.count)
    let rules = toolCalls.map { ($0, $0.scope.cutoff(messageCount: messages.count)) }
    var pruned: [UIMessage] = []

    for (index, message) in messages.enumerated() {
        var message = message
        message.parts.removeAll { part in
            switch part {
            case .reasoning:
                index < reasoningCutoff
            case .tool(let tool):
                rules.contains { rule, cutoff in
                    index < cutoff && rule.matches(tool.toolName)
                }
            default:
                false
            }
        }
        pruned.append(message)
    }

    guard emptyMessages == .remove else { return pruned }
    return pruned.filter { message in
        message.parts.contains { part in
            if case .stepStart = part { return false }
            return true
        }
    }
}

public func pruneMessages(
    _ messages: [UIMessage],
    reasoning: PruneScope = .none,
    toolCalls: PruneToolCalls,
    emptyMessages: PruneEmptyMessages = .remove
) -> [UIMessage] {
    pruneMessages(
        messages, reasoning: reasoning, toolCalls: [toolCalls], emptyMessages: emptyMessages
    )
}

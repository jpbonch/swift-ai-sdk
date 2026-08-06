import AI
import Foundation

public struct TokenUsageSummary: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens ?? (inputTokens + outputTokens)
    }

    public static func from(metadata: JSONValue?) -> TokenUsageSummary? {
        guard let usage = metadata?["usage"] else { return nil }
        let input = usage["inputTokens"]?.intValue ?? usage["promptTokens"]?.intValue
        let output = usage["outputTokens"]?.intValue ?? usage["completionTokens"]?.intValue
        let total = usage["totalTokens"]?.intValue
        guard input != nil || output != nil || total != nil else { return nil }
        return TokenUsageSummary(
            inputTokens: input ?? 0, outputTokens: output ?? 0, totalTokens: total
        )
    }
}

public struct PendingApproval: Sendable, Hashable {
    public var approvalID: String
    public var toolCallID: String
    public var toolName: String
}

public struct AgentTUIModel: Sendable {
    public enum Status: Sendable, Equatable {
        case ready
        case submitted
        case streaming
        case error(String)
    }

    public var title: String
    public var messages: [UIMessage]
    public var status: Status
    public var input: String
    public var cursor: Int
    public var scrollOffset: Int
    public var transcript: TerminalTranscriptOptions
    public var responseStatistics: ResponseStatisticsMode
    public var contextSize: Int?
    public var usage: TokenUsageSummary?
    public var responseStartedAt: Date?
    public var responseDuration: TimeInterval?
    public var spinnerFrame: Int

    public init(
        title: String = "Assistant",
        messages: [UIMessage] = [],
        transcript: TerminalTranscriptOptions = TerminalTranscriptOptions(),
        responseStatistics: ResponseStatisticsMode = .outputTokensPerSecond,
        contextSize: Int? = nil
    ) {
        self.title = title
        self.messages = messages
        self.status = .ready
        self.input = ""
        self.cursor = 0
        self.scrollOffset = 0
        self.transcript = transcript
        self.responseStatistics = responseStatistics
        self.contextSize = contextSize
        self.usage = nil
        self.responseStartedAt = nil
        self.responseDuration = nil
        self.spinnerFrame = 0
    }

    public var isBusy: Bool {
        status == .submitted || status == .streaming
    }

    public var pendingApproval: PendingApproval? {
        for message in messages.reversed() {
            for part in message.parts {
                guard case .tool(let tool) = part,
                      tool.state == .approvalRequested,
                      let approval = tool.approval
                else { continue }
                return PendingApproval(
                    approvalID: approval.id,
                    toolCallID: tool.toolCallID,
                    toolName: tool.toolName.isEmpty ? "tool" : tool.toolName
                )
            }
        }
        return nil
    }

    public mutating func insert(_ character: Character) {
        let index = input.index(input.startIndex, offsetBy: min(cursor, input.count))
        input.insert(character, at: index)
        cursor += 1
    }

    public mutating func deleteBackward() {
        guard cursor > 0, !input.isEmpty else { return }
        let index = input.index(input.startIndex, offsetBy: cursor - 1)
        input.remove(at: index)
        cursor -= 1
    }

    public mutating func deleteWord() {
        guard cursor > 0 else { return }
        var end = cursor
        while end > 0, input[input.index(input.startIndex, offsetBy: end - 1)] == " " {
            end -= 1
        }
        while end > 0, input[input.index(input.startIndex, offsetBy: end - 1)] != " " {
            end -= 1
        }
        let range = input.index(input.startIndex, offsetBy: end)
            ..< input.index(input.startIndex, offsetBy: cursor)
        input.removeSubrange(range)
        cursor = end
    }

    public mutating func clearInput() {
        input.removeAll()
        cursor = 0
    }

    public mutating func moveCursor(by delta: Int) {
        cursor = min(max(cursor + delta, 0), input.count)
    }

    public mutating func moveCursorToStart() { cursor = 0 }

    public mutating func moveCursorToEnd() { cursor = input.count }

    public mutating func takeInput() -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        clearInput()
        return text
    }

    public mutating func appendUserMessage(_ text: String) {
        messages.append(.user(text))
        scrollOffset = 0
    }

    @discardableResult
    public mutating func respondToApproval(
        approvalID: String, approved: Bool, reason: String? = nil
    ) -> Bool {
        guard let messageIndex = messages.lastIndex(where: { message in
            message.parts.contains {
                if case .tool(let tool) = $0 { return tool.approval?.id == approvalID }
                return false
            }
        }) else { return false }

        var message = messages[messageIndex]
        for (partIndex, part) in message.parts.enumerated() {
            guard case .tool(var tool) = part, tool.approval?.id == approvalID else { continue }
            tool.state = .approvalResponded
            tool.approval = ToolApproval(
                id: approvalID,
                approved: approved,
                reason: reason,
                signature: tool.approval?.signature
            )
            message.parts[partIndex] = .tool(tool)
        }
        messages[messageIndex] = message

        return !message.parts.contains {
            if case .tool(let tool) = $0 { return tool.state == .approvalRequested }
            return false
        }
    }

    public mutating func scroll(by lines: Int, viewportHeight: Int, contentHeight: Int) {
        let maximum = max(contentHeight - viewportHeight, 0)
        scrollOffset = min(max(scrollOffset + lines, 0), maximum)
    }

    public var statistics: String? {
        guard let usage, usage.outputTokens > 0 else { return nil }
        switch responseStatistics {
        case .outputTokenCount:
            return "\(usage.outputTokens) output tokens"
        case .outputTokensPerSecond:
            guard let duration = responseDuration, duration > 0.05 else { return nil }
            let rate = Double(usage.outputTokens) / duration
            return String(format: "%.1f tok/s", rate)
        }
    }

    public var contextUsage: String? {
        guard let contextSize, contextSize > 0, let usage, usage.totalTokens > 0 else { return nil }
        let percent = Double(usage.totalTokens) / Double(contextSize) * 100
        return String(format: "%@/%@ ctx (%.0f%%)",
                      compact(usage.totalTokens), compact(contextSize), percent)
    }

    private func compact(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        let thousands = Double(value) / 1000
        return thousands == thousands.rounded()
            ? String(format: "%.0fk", thousands)
            : String(format: "%.1fk", thousands)
    }
}

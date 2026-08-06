import Foundation

public enum TerminalPartDisplayMode: String, Sendable, Hashable, CaseIterable {
    case full
    case collapsed
    case autoCollapsed = "auto-collapsed"
    case hidden
}

public enum ResponseStatisticsMode: String, Sendable, Hashable, CaseIterable {
    case outputTokenCount
    case outputTokensPerSecond
}

public struct TerminalTranscriptOptions: Sendable {
    public var tools: TerminalPartDisplayMode
    public var reasoning: TerminalPartDisplayMode
    public var theme: TerminalTheme

    public init(
        tools: TerminalPartDisplayMode = .autoCollapsed,
        reasoning: TerminalPartDisplayMode = .autoCollapsed,
        theme: TerminalTheme = .default
    ) {
        self.tools = tools
        self.reasoning = reasoning
        self.theme = theme
    }
}

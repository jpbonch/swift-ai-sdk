import AI
import Foundation

public enum TranscriptRenderer {

    public static func lines(
        for messages: [UIMessage],
        width: Int,
        options: TerminalTranscriptOptions = TerminalTranscriptOptions()
    ) -> [StyledLine] {
        let lastSection = lastVisibleSection(in: messages, options: options)
        var output: [StyledLine] = []

        for message in messages {
            let rendered = lines(
                for: message, width: width, options: options, lastSection: lastSection
            )
            guard !rendered.isEmpty else { continue }
            if !output.isEmpty { output.append(StyledLine()) }
            output.append(contentsOf: rendered)
        }
        return output
    }

    struct SectionKey: Hashable {
        var messageID: String
        var partIndex: Int
    }

    static func lastVisibleSection(
        in messages: [UIMessage], options: TerminalTranscriptOptions
    ) -> SectionKey? {
        var last: SectionKey?
        for message in messages where message.role == .assistant {
            for (index, part) in message.parts.enumerated() {
                switch part {
                case .text(let text) where !text.text.isEmpty:
                    last = SectionKey(messageID: message.id, partIndex: index)
                case .reasoning where options.reasoning != .hidden:
                    last = SectionKey(messageID: message.id, partIndex: index)
                case .tool where options.tools != .hidden:
                    last = SectionKey(messageID: message.id, partIndex: index)
                default:
                    continue
                }
            }
        }
        return last
    }

    static func lines(
        for message: UIMessage,
        width: Int,
        options: TerminalTranscriptOptions,
        lastSection: SectionKey?
    ) -> [StyledLine] {
        switch message.role {
        case .user:
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let prefix = [StyledRun("› ", style: TerminalStyle(color: .cyan, bold: true))]
            return MarkdownTerminalRenderer.wrap(
                [StyledRun(text, style: TerminalStyle(bold: true))],
                width: width,
                firstPrefix: prefix,
                continuationPrefix: [StyledRun("  ")]
            )

        case .system:
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return MarkdownTerminalRenderer.wrap(
                [StyledRun(text, style: TerminalStyle(dim: true))], width: width
            )

        case .assistant:
            var output: [StyledLine] = []
            for (index, part) in message.parts.enumerated() {
                let key = SectionKey(messageID: message.id, partIndex: index)
                let isLast = key == lastSection
                let rendered = lines(
                    for: part, width: width, options: options, isLastSection: isLast
                )
                guard !rendered.isEmpty else { continue }
                if !output.isEmpty { output.append(StyledLine()) }
                output.append(contentsOf: rendered)
            }
            return output
        }
    }

    static func lines(
        for part: UIPart,
        width: Int,
        options: TerminalTranscriptOptions,
        isLastSection: Bool
    ) -> [StyledLine] {
        switch part {
        case .text(let text):
            let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return MarkdownTerminalRenderer.render(trimmed, width: width, theme: options.theme)

        case .reasoning(let reasoning):
            return reasoningLines(
                reasoning, width: width, options: options, isLastSection: isLastSection
            )

        case .tool(let tool):
            return toolLines(tool, width: width, options: options, isLastSection: isLastSection)

        case .sourceURL(let source):
            let label = source.title ?? source.url
            return MarkdownTerminalRenderer.wrap(
                [
                    StyledRun("↗ ", style: TerminalStyle(color: .blue)),
                    StyledRun(label, style: TerminalStyle(dim: true))
                ],
                width: width, continuationPrefix: [StyledRun("  ")]
            )

        case .sourceDocument(let source):
            return MarkdownTerminalRenderer.wrap(
                [
                    StyledRun("↗ ", style: TerminalStyle(color: .blue)),
                    StyledRun(source.title, style: TerminalStyle(dim: true))
                ],
                width: width, continuationPrefix: [StyledRun("  ")]
            )

        case .file(let file):
            return [StyledLine([
                StyledRun("⎘ ", style: TerminalStyle(color: .magenta)),
                StyledRun(file.mediaType, style: TerminalStyle(dim: true))
            ])]

        case .data, .stepStart:
            return []
        }
    }

    static func reasoningLines(
        _ reasoning: ReasoningUIPart,
        width: Int,
        options: TerminalTranscriptOptions,
        isLastSection: Bool
    ) -> [StyledLine] {
        let trimmed = reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard options.reasoning != .hidden, !trimmed.isEmpty else { return [] }

        let style = TerminalStyle(color: .magenta)
        let isStreaming = reasoning.state == .streaming
        let header = StyledLine([
            StyledRun("◆ ", style: style),
            StyledRun("Reasoning", style: style.merged(with: TerminalStyle(bold: true))),
            StyledRun(isStreaming ? " …" : "", style: TerminalStyle(dim: true))
        ])

        guard expanded(options.reasoning, isLastSection: isLastSection) else {
            let summary = TerminalText.truncate(
                trimmed.replacingOccurrences(of: "\n", with: " "), to: max(width - 14, 8)
            )
            return [StyledLine(header.runs + [StyledRun("  \(summary)", style: TerminalStyle(dim: true))])]
        }

        let body = MarkdownTerminalRenderer.wrap(
            [StyledRun(trimmed, style: TerminalStyle(dim: true))],
            width: width,
            firstPrefix: [StyledRun("  ")],
            continuationPrefix: [StyledRun("  ")]
        )
        return [header] + body
    }

    static func toolLines(
        _ tool: ToolUIPart,
        width: Int,
        options: TerminalTranscriptOptions,
        isLastSection: Bool
    ) -> [StyledLine] {
        guard options.tools != .hidden else { return [] }

        let indicator = stateIndicator(tool.state)
        let name = tool.toolName.isEmpty ? "tool" : tool.toolName
        var header: [StyledRun] = [
            StyledRun("\(indicator.glyph) ", style: indicator.style),
            StyledRun(name, style: TerminalStyle(bold: true)),
            StyledRun("  \(indicator.label)", style: TerminalStyle(dim: true))
        ]

        let mustExpand = tool.state == .approvalRequested
        guard mustExpand || expanded(options.tools, isLastSection: isLastSection) else {
            if let input = tool.input {
                let summary = TerminalText.truncate(
                    compactJSON(input), to: max(width - TerminalText.width(name) - 16, 8)
                )
                header.append(StyledRun("  \(summary)", style: TerminalStyle(dim: true)))
            }
            return [StyledLine(header)]
        }

        var output: [StyledLine] = [StyledLine(header)]
        if let input = tool.input {
            output.append(contentsOf: field("input", value: prettyJSON(input), width: width))
        }
        if let value = tool.output {
            output.append(contentsOf: field("output", value: prettyJSON(value), width: width))
        }
        if let errorText = tool.errorText {
            output.append(contentsOf: field(
                "error", value: errorText, width: width, style: TerminalStyle(color: .red)
            ))
        }
        if tool.state == .outputDenied {
            output.append(contentsOf: field(
                "output", value: tool.approval?.reason ?? "Tool execution denied.",
                width: width, style: TerminalStyle(color: .yellow)
            ))
        }
        return output
    }

    static func expanded(_ mode: TerminalPartDisplayMode, isLastSection: Bool) -> Bool {
        switch mode {
        case .full: true
        case .collapsed: false
        case .autoCollapsed: isLastSection
        case .hidden: false
        }
    }

    static func stateIndicator(
        _ state: UIToolState
    ) -> (glyph: String, label: String, style: TerminalStyle) {
        switch state {
        case .inputStreaming:
            ("⚙", "calling", TerminalStyle(color: .yellow))
        case .inputAvailable:
            ("⚙", "running", TerminalStyle(color: .yellow))
        case .approvalRequested:
            ("?", "needs approval", TerminalStyle(color: .yellow, bold: true))
        case .approvalResponded:
            ("⚙", "approved", TerminalStyle(color: .yellow))
        case .outputAvailable:
            ("✓", "done", TerminalStyle(color: .green))
        case .outputError:
            ("✗", "error", TerminalStyle(color: .red))
        case .outputDenied:
            ("⊘", "denied", TerminalStyle(color: .yellow))
        }
    }

    static func field(
        _ label: String,
        value: String,
        width: Int,
        style: TerminalStyle = TerminalStyle(dim: true)
    ) -> [StyledLine] {
        let labelRun = StyledRun("  \(label): ", style: TerminalStyle(dim: true))
        let indent = StyledRun(String(repeating: " ", count: label.count + 4))
        let body = value.components(separatedBy: "\n")
        var output: [StyledLine] = []
        for (index, line) in body.enumerated() {
            let prefix = index == 0 ? [labelRun] : [indent]
            output.append(contentsOf: MarkdownTerminalRenderer.wrap(
                [StyledRun(line, style: style)],
                width: width, firstPrefix: prefix, continuationPrefix: [indent]
            ))
        }
        return output
    }

    public static func prettyJSON(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return text
    }

    public static func compactJSON(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return text
    }
}

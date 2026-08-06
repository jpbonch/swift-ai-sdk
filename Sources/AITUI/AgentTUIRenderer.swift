import AI
import Foundation

public struct AgentTUIFrame: Sendable, Hashable {
    public var rows: [String]
    public var cursorRow: Int
    public var cursorColumn: Int

    public init(rows: [String], cursorRow: Int, cursorColumn: Int) {
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
    }
}

public enum AgentTUIRenderer {

    public static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    public static let promptPrefix = "› "

    public static func transcriptLines(model: AgentTUIModel, width: Int) -> [StyledLine] {
        guard !model.messages.isEmpty else {
            return [
                StyledLine(model.title, style: TerminalStyle(bold: true)),
                StyledLine(),
                StyledLine(
                    "Type a message and press Enter. Esc quits.",
                    style: TerminalStyle(dim: true)
                )
            ]
        }
        var lines = TranscriptRenderer.lines(
            for: model.messages, width: width, options: model.transcript
        )
        if case .error(let text) = model.status {
            lines.append(StyledLine())
            lines.append(contentsOf: MarkdownTerminalRenderer.wrap(
                [
                    StyledRun("✗ ", style: TerminalStyle(color: .red, bold: true)),
                    StyledRun(text, style: TerminalStyle(color: .red))
                ],
                width: width, continuationPrefix: [StyledRun("  ")]
            ))
        }
        return lines
    }

    public static func chromeHeight(model: AgentTUIModel) -> Int {
        model.pendingApproval != nil && !model.isBusy ? 4 : 3
    }

    public static func viewportHeight(model: AgentTUIModel, size: TerminalSize) -> Int {
        max(size.rows - chromeHeight(model: model), 1)
    }

    public static func frame(
        model: AgentTUIModel, size: TerminalSize, styled: Bool = true
    ) -> AgentTUIFrame {
        let width = max(size.columns, 20)
        let viewport = viewportHeight(model: model, size: size)
        let content = transcriptLines(model: model, width: width)

        let maximumOffset = max(content.count - viewport, 0)
        let offset = min(model.scrollOffset, maximumOffset)
        let end = content.count - offset
        let start = max(end - viewport, 0)
        var visible = Array(content[start..<max(end, start)])
        while visible.count < viewport { visible.append(StyledLine()) }

        var rows = visible.map { render($0, width: width, styled: styled) }
        rows.append(render(
            StyledLine(String(repeating: "─", count: width), style: TerminalStyle(dim: true)),
            width: width, styled: styled
        ))
        rows.append(render(statusLine(model: model, width: width), width: width, styled: styled))

        if let approval = model.pendingApproval, !model.isBusy {
            rows.append(render(approvalLine(approval, width: width), width: width, styled: styled))
        }

        let (inputLine, cursorColumn) = inputLine(model: model, width: width)
        rows.append(render(inputLine, width: width, styled: styled))

        return AgentTUIFrame(
            rows: rows, cursorRow: rows.count, cursorColumn: cursorColumn
        )
    }

    static func statusLine(model: AgentTUIModel, width: Int) -> StyledLine {
        var runs: [StyledRun] = [
            StyledRun(model.title, style: TerminalStyle(color: .cyan, bold: true))
        ]

        let separator = StyledRun(" · ", style: TerminalStyle(dim: true))
        switch model.status {
        case .ready:
            runs.append(separator)
            runs.append(StyledRun("ready", style: TerminalStyle(dim: true)))
        case .submitted, .streaming:
            let spinner = spinnerFrames[model.spinnerFrame % spinnerFrames.count]
            runs.append(separator)
            runs.append(StyledRun("\(spinner) ", style: TerminalStyle(color: .yellow)))
            runs.append(StyledRun(
                model.status == .submitted ? "waiting" : "streaming",
                style: TerminalStyle(color: .yellow)
            ))
            if let started = model.responseStartedAt {
                let elapsed = Date().timeIntervalSince(started)
                runs.append(StyledRun(
                    String(format: " %.1fs", elapsed), style: TerminalStyle(dim: true)
                ))
            }
        case .error:
            runs.append(separator)
            runs.append(StyledRun("error", style: TerminalStyle(color: .red, bold: true)))
        }

        if let statistics = model.statistics {
            runs.append(separator)
            runs.append(StyledRun(statistics, style: TerminalStyle(dim: true)))
        }
        if let context = model.contextUsage {
            runs.append(separator)
            runs.append(StyledRun(context, style: TerminalStyle(dim: true)))
        }
        if model.scrollOffset > 0 {
            runs.append(separator)
            runs.append(StyledRun(
                "scrolled +\(model.scrollOffset)", style: TerminalStyle(color: .yellow)
            ))
        }

        let hints = "enter send · ↑↓ scroll · esc quit"
        let used = runs.reduce(0) { $0 + TerminalText.width($1.text) }
        let gap = width - used - TerminalText.width(hints)
        if gap > 2 {
            runs.append(StyledRun(String(repeating: " ", count: gap)))
            runs.append(StyledRun(hints, style: TerminalStyle(dim: true)))
        }
        return StyledLine(runs)
    }

    static func approvalLine(_ approval: PendingApproval, width: Int) -> StyledLine {
        StyledLine([
            StyledRun("? ", style: TerminalStyle(color: .yellow, bold: true)),
            StyledRun("Run tool ", style: TerminalStyle(color: .yellow)),
            StyledRun(approval.toolName, style: TerminalStyle(color: .yellow, bold: true)),
            StyledRun("?  ", style: TerminalStyle(color: .yellow)),
            StyledRun("y", style: TerminalStyle(color: .green, bold: true)),
            StyledRun(" approve · ", style: TerminalStyle(dim: true)),
            StyledRun("n", style: TerminalStyle(color: .red, bold: true)),
            StyledRun(" deny", style: TerminalStyle(dim: true))
        ])
    }

    static func inputLine(model: AgentTUIModel, width: Int) -> (StyledLine, Int) {
        let available = max(width - TerminalText.width(promptPrefix), 4)
        let characters = Array(model.input)
        let cursor = min(model.cursor, characters.count)

        var start = 0
        if cursor > available - 1 { start = cursor - available + 1 }
        let end = min(characters.count, start + available)
        let visible = String(characters[start..<end])

        let style = model.isBusy ? TerminalStyle(dim: true) : TerminalStyle()
        let prefixStyle = model.isBusy
            ? TerminalStyle(dim: true)
            : TerminalStyle(color: .cyan, bold: true)

        var runs = [StyledRun(promptPrefix, style: prefixStyle)]
        if visible.isEmpty {
            runs.append(StyledRun(
                model.isBusy ? "working…" : "", style: TerminalStyle(dim: true)
            ))
        } else {
            runs.append(StyledRun(visible, style: style))
        }

        let column = TerminalText.width(promptPrefix)
            + TerminalText.width(String(characters[start..<cursor])) + 1
        return (StyledLine(runs), min(column, width))
    }

    static func render(_ line: StyledLine, width: Int, styled: Bool) -> String {
        var runs: [StyledRun] = []
        var used = 0
        for run in line.runs {
            let runWidth = TerminalText.width(run.text)
            if used + runWidth <= width {
                runs.append(run)
                used += runWidth
                continue
            }
            let remaining = width - used
            if remaining > 0 {
                runs.append(StyledRun(
                    TerminalText.truncate(run.text, to: remaining, ellipsis: "…"),
                    style: run.style
                ))
            }
            break
        }
        return StyledLine(runs).render(styled: styled)
    }
}

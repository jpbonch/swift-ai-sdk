import Foundation

public struct TerminalTheme: Sendable, Hashable {
    public var heading: TerminalStyle
    public var bold: TerminalStyle
    public var italic: TerminalStyle
    public var strikethrough: TerminalStyle
    public var code: TerminalStyle
    public var codeBlock: TerminalStyle
    public var quote: TerminalStyle
    public var link: TerminalStyle
    public var linkURL: TerminalStyle
    public var listMarker: TerminalStyle
    public var rule: TerminalStyle

    public init(
        heading: TerminalStyle = TerminalStyle(color: .cyan, bold: true),
        bold: TerminalStyle = TerminalStyle(bold: true),
        italic: TerminalStyle = TerminalStyle(italic: true),
        strikethrough: TerminalStyle = TerminalStyle(strikethrough: true),
        code: TerminalStyle = TerminalStyle(color: .yellow),
        codeBlock: TerminalStyle = TerminalStyle(color: .green),
        quote: TerminalStyle = TerminalStyle(dim: true),
        link: TerminalStyle = TerminalStyle(color: .blue, underline: true),
        linkURL: TerminalStyle = TerminalStyle(dim: true),
        listMarker: TerminalStyle = TerminalStyle(color: .cyan),
        rule: TerminalStyle = TerminalStyle(dim: true)
    ) {
        self.heading = heading
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
        self.codeBlock = codeBlock
        self.quote = quote
        self.link = link
        self.linkURL = linkURL
        self.listMarker = listMarker
        self.rule = rule
    }

    public static let `default` = TerminalTheme()
}

public enum MarkdownTerminalRenderer {

    public static func render(
        _ markdown: String,
        width: Int,
        theme: TerminalTheme = .default
    ) -> [StyledLine] {
        let usableWidth = max(width, 8)
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        var output: [StyledLine] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ")
            output.append(contentsOf: wrap(inline(text, theme: theme), width: usableWidth))
            paragraph.removeAll()
        }

        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                output.append(contentsOf: codeBlock(body, width: usableWidth, theme: theme))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                output.append(StyledLine())
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                output.append(StyledLine(String(repeating: "─", count: usableWidth), style: theme.rule))
                continue
            }

            if let (level, text) = heading(trimmed) {
                flushParagraph()
                let marker = String(repeating: "#", count: level) + " "
                var runs = [StyledRun(marker, style: theme.heading)]
                runs.append(contentsOf: inline(text, theme: theme).map {
                    StyledRun($0.text, style: theme.heading.merged(with: $0.style))
                })
                output.append(contentsOf: wrap(
                    runs, width: usableWidth,
                    continuationPrefix: [StyledRun(String(repeating: " ", count: marker.count))]
                ))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let prefix = [StyledRun("│ ", style: theme.quote)]
                output.append(contentsOf: wrap(
                    inline(inner, theme: theme).map {
                        StyledRun($0.text, style: theme.quote.merged(with: $0.style))
                    },
                    width: usableWidth, firstPrefix: prefix, continuationPrefix: prefix
                ))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                let indent = String(repeating: " ", count: item.indent)
                let prefix = [
                    StyledRun(indent),
                    StyledRun(item.marker, style: theme.listMarker)
                ]
                let continuation = [
                    StyledRun(indent + String(repeating: " ", count: item.marker.count))
                ]
                output.append(contentsOf: wrap(
                    inline(item.text, theme: theme),
                    width: usableWidth, firstPrefix: prefix, continuationPrefix: continuation
                ))
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        while output.last?.runs.isEmpty == true { output.removeLast() }
        return output
    }

    static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker: Character in ["-", "*", "_"] {
            if trimmed.allSatisfy({ $0 == marker }) { return true }
        }
        return false
    }

    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return (leading, "• ", String(trimmed.dropFirst(bullet.count)))
        }

        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                return (leading, "\(digits). ", String(afterDigits.dropFirst(2)))
            }
        }
        return nil
    }

    static func codeBlock(
        _ body: [String], width: Int, theme: TerminalTheme
    ) -> [StyledLine] {
        let bar = StyledRun("│ ", style: theme.quote)
        let available = max(width - 2, 4)
        return body.flatMap { line -> [StyledLine] in
            guard !line.isEmpty else { return [StyledLine([bar])] }
            return hardSplit(line, width: available).map {
                StyledLine([bar, StyledRun($0, style: theme.codeBlock)])
            }
        }
    }

    static func inline(_ text: String, theme: TerminalTheme) -> [StyledRun] {
        var runs: [StyledRun] = []
        var buffer = ""
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(StyledRun(buffer))
            buffer = ""
        }

        while index < text.endIndex {
            let rest = text[index...]

            if rest.hasPrefix("`"), let close = findClosing(rest.dropFirst(), marker: "`") {
                flush()
                let content = String(rest.dropFirst()[..<close])
                runs.append(StyledRun(content, style: theme.code))
                index = rest.index(after: close)
                continue
            }

            if rest.hasPrefix("**"), let close = findClosing(rest.dropFirst(2), marker: "**") {
                flush()
                let content = String(rest.dropFirst(2)[..<close])
                runs.append(contentsOf: inline(content, theme: theme).map {
                    StyledRun($0.text, style: theme.bold.merged(with: $0.style))
                })
                index = rest.index(close, offsetBy: 2)
                continue
            }

            if rest.hasPrefix("~~"), let close = findClosing(rest.dropFirst(2), marker: "~~") {
                flush()
                let content = String(rest.dropFirst(2)[..<close])
                runs.append(contentsOf: inline(content, theme: theme).map {
                    StyledRun($0.text, style: theme.strikethrough.merged(with: $0.style))
                })
                index = rest.index(close, offsetBy: 2)
                continue
            }

            if let marker = ["*", "_"].first(where: { rest.hasPrefix($0) }),
               let close = findClosing(rest.dropFirst(), marker: marker),
               close > rest.index(after: rest.startIndex) {
                flush()
                let content = String(rest.dropFirst()[..<close])
                runs.append(contentsOf: inline(content, theme: theme).map {
                    StyledRun($0.text, style: theme.italic.merged(with: $0.style))
                })
                index = rest.index(after: close)
                continue
            }

            if rest.hasPrefix("["), let link = parseLink(rest) {
                flush()
                runs.append(StyledRun(link.label, style: theme.link))
                if !link.url.isEmpty {
                    runs.append(StyledRun(" (\(link.url))", style: theme.linkURL))
                }
                index = link.end
                continue
            }

            buffer.append(text[index])
            index = text.index(after: index)
        }

        flush()
        return runs
    }

    private static func findClosing(
        _ text: Substring, marker: String
    ) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(marker) { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseLink(
        _ text: Substring
    ) -> (label: String, url: String, end: Substring.Index)? {
        guard let labelEnd = findClosing(text.dropFirst(), marker: "]") else { return nil }
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        guard let urlEnd = findClosing(text[text.index(after: afterLabel)...], marker: ")")
        else { return nil }
        let label = String(text.dropFirst()[..<labelEnd])
        let url = String(text[text.index(after: afterLabel)..<urlEnd])
        return (label, url, text.index(after: urlEnd))
    }

    public static func wrap(
        _ runs: [StyledRun],
        width: Int,
        firstPrefix: [StyledRun] = [],
        continuationPrefix: [StyledRun] = []
    ) -> [StyledLine] {
        let limit = max(width, 4)
        var lines: [StyledLine] = []
        var current = firstPrefix
        var used = firstPrefix.reduce(0) { $0 + TerminalText.width($1.text) }
        var isFirstLine = true

        func flush() {
            lines.append(StyledLine(trimmingTrailingWhitespace(current)))
            current = continuationPrefix
            used = continuationPrefix.reduce(0) { $0 + TerminalText.width($1.text) }
            isFirstLine = false
        }

        var hasContent = false
        for token in tokenize(runs) {
            let tokenWidth = TerminalText.width(token.text)
            if token.isWhitespace {
                if !hasContent { continue }
                if used + tokenWidth > limit { flush(); hasContent = false; continue }
                current.append(StyledRun(token.text, style: token.style))
                used += tokenWidth
                continue
            }

            if used + tokenWidth <= limit {
                current.append(StyledRun(token.text, style: token.style))
                used += tokenWidth
                hasContent = true
                continue
            }

            if hasContent { flush(); hasContent = false }

            if tokenWidth <= limit - used {
                current.append(StyledRun(token.text, style: token.style))
                used += tokenWidth
                hasContent = true
                continue
            }

            for piece in hardSplit(token.text, width: limit - used) {
                if used + TerminalText.width(piece) > limit, hasContent {
                    flush()
                    hasContent = false
                }
                current.append(StyledRun(piece, style: token.style))
                used += TerminalText.width(piece)
                hasContent = true
                if used >= limit { flush(); hasContent = false }
            }
        }

        if hasContent {
            lines.append(StyledLine(trimmingTrailingWhitespace(current)))
        } else if isFirstLine, lines.isEmpty {
            lines.append(StyledLine(current))
        }
        return lines.isEmpty ? [StyledLine()] : lines
    }

    private static func trimmingTrailingWhitespace(_ runs: [StyledRun]) -> [StyledRun] {
        var result = runs
        while let last = result.last {
            let trimmed = String(
                last.text.reversed().drop { $0 == " " || $0 == "\t" }.reversed()
            )
            if trimmed.isEmpty {
                result.removeLast()
                continue
            }
            if trimmed != last.text {
                result[result.count - 1] = StyledRun(trimmed, style: last.style)
            }
            break
        }
        return result
    }

    private struct Token {
        var text: String
        var style: TerminalStyle
        var isWhitespace: Bool
    }

    private static func tokenize(_ runs: [StyledRun]) -> [Token] {
        var tokens: [Token] = []
        for run in runs {
            var buffer = ""
            var bufferIsWhitespace: Bool?
            for character in run.text {
                let isWhitespace = character == " " || character == "\t"
                if bufferIsWhitespace == nil { bufferIsWhitespace = isWhitespace }
                if isWhitespace != bufferIsWhitespace {
                    tokens.append(Token(
                        text: buffer, style: run.style, isWhitespace: bufferIsWhitespace ?? false
                    ))
                    buffer = ""
                    bufferIsWhitespace = isWhitespace
                }
                buffer.append(character)
            }
            if !buffer.isEmpty {
                tokens.append(Token(
                    text: buffer, style: run.style, isWhitespace: bufferIsWhitespace ?? false
                ))
            }
        }
        return tokens
    }

    static func hardSplit(_ text: String, width: Int) -> [String] {
        let limit = max(width, 1)
        var pieces: [String] = []
        var current = ""
        var used = 0
        for character in text {
            let characterWidth = TerminalText.width(of: character)
            if used + characterWidth > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
                used = 0
            }
            current.append(character)
            used += characterWidth
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [""] : pieces
    }
}

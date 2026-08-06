import Foundation

public enum TerminalColor: Sendable, Hashable {
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case gray

    var code: Int {
        switch self {
        case .red: 31
        case .green: 32
        case .yellow: 33
        case .blue: 34
        case .magenta: 35
        case .cyan: 36
        case .white: 37
        case .gray: 90
        }
    }
}

public struct TerminalStyle: Sendable, Hashable {
    public var color: TerminalColor?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool

    public init(
        color: TerminalColor? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        self.color = color
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }

    public static let plain = TerminalStyle()

    public var isPlain: Bool { self == .plain }

    var codes: [Int] {
        var codes: [Int] = []
        if bold { codes.append(1) }
        if dim { codes.append(2) }
        if italic { codes.append(3) }
        if underline { codes.append(4) }
        if strikethrough { codes.append(9) }
        if let color { codes.append(color.code) }
        return codes
    }

    public func merged(with other: TerminalStyle) -> TerminalStyle {
        TerminalStyle(
            color: other.color ?? color,
            bold: bold || other.bold,
            dim: dim || other.dim,
            italic: italic || other.italic,
            underline: underline || other.underline,
            strikethrough: strikethrough || other.strikethrough
        )
    }

    public func apply(_ text: String, enabled: Bool = true) -> String {
        guard enabled, !isPlain, !text.isEmpty else { return text }
        let prefix = codes.map(String.init).joined(separator: ";")
        return "\u{1B}[\(prefix)m\(text)\u{1B}[0m"
    }
}

public struct StyledRun: Sendable, Hashable {
    public var text: String
    public var style: TerminalStyle

    /// Text is sanitized here rather than at each call site. Everything a run
    /// carries — model output, tool arguments, tool results, error strings —
    /// comes from somewhere the terminal should not be taking orders from, and
    /// this is the one place all of it passes through.
    public init(_ text: String, style: TerminalStyle = .plain) {
        self.text = TerminalText.sanitize(text)
        self.style = style
    }
}

public struct StyledLine: Sendable, Hashable {
    public var runs: [StyledRun]

    public init(_ runs: [StyledRun] = []) {
        self.runs = runs
    }

    public init(_ text: String, style: TerminalStyle = .plain) {
        self.runs = text.isEmpty ? [] : [StyledRun(text, style: style)]
    }

    public var plainText: String {
        runs.map(\.text).joined()
    }

    public var width: Int {
        runs.reduce(0) { $0 + TerminalText.width($1.text) }
    }

    public func render(styled: Bool) -> String {
        guard styled else { return plainText }
        var merged: [StyledRun] = []
        for run in runs {
            if let last = merged.last, last.style == run.style {
                merged[merged.count - 1] = StyledRun(last.text + run.text, style: run.style)
            } else {
                merged.append(run)
            }
        }
        return merged.map { $0.style.apply($0.text, enabled: true) }.joined()
    }
}

public enum TerminalText {
    /// Replaces the control characters a terminal acts on with a visible
    /// marker, keeping only tab and newline.
    ///
    /// Without this, anything that can put text on screen can also move the
    /// cursor, clear the display, or swallow the output that follows — enough
    /// to redraw the tool-approval prompt as something the user would say yes
    /// to. C1 is included because `\u{9B}` and `\u{9D}` are eight-bit CSI and
    /// OSC.
    public static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isControl(scalar) {
                result.append(contentsOf: "\u{FFFD}".unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" { return false }
        return scalar.value < 0x20
            || scalar.value == 0x7F
            || (scalar.value >= 0x80 && scalar.value <= 0x9F)
    }

    public static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    public static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        // A control character occupies no column. Counting it as one let an
        // escape sequence survive truncation with its width mis-measured.
        if isControl(scalar) { return 0 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        return isWide(scalar) ? 2 : 1
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    public static func truncate(_ text: String, to limit: Int, ellipsis: String = "…") -> String {
        guard limit > 0 else { return "" }
        guard width(text) > limit else { return text }
        let ellipsisWidth = width(ellipsis)
        var result = ""
        var used = 0
        for character in text {
            let next = width(of: character)
            if used + next > limit - ellipsisWidth { break }
            result.append(character)
            used += next
        }
        return result + ellipsis
    }

    public static func pad(_ text: String, to target: Int) -> String {
        let missing = target - width(text)
        return missing > 0 ? text + String(repeating: " ", count: missing) : text
    }
}

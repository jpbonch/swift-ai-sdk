import Foundation

public enum TerminalKey: Sendable, Hashable {
    case character(Character)
    case enter
    case backspace
    case tab
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case escape
    case interrupt
    case repaint
    case clearLine
    case deleteWord
}

public struct TerminalKeyDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public var hasPendingEscape: Bool {
        pending.first == 0x1B
    }

    public mutating func flushEscape() -> [TerminalKey] {
        guard hasPendingEscape else { return [] }
        pending.removeAll()
        return [.escape]
    }

    public mutating func feed(_ bytes: [UInt8]) -> [TerminalKey] {
        pending.append(contentsOf: bytes)
        var keys: [TerminalKey] = []

        while !pending.isEmpty {
            let byte = pending[0]

            if byte == 0x1B {
                guard let (key, consumed) = decodeEscape(pending) else { break }
                pending.removeFirst(consumed)
                if let key { keys.append(key) }
                continue
            }

            switch byte {
            case 0x03:
                pending.removeFirst()
                keys.append(.interrupt)
                continue
            case 0x0C:
                pending.removeFirst()
                keys.append(.repaint)
                continue
            case 0x15:
                pending.removeFirst()
                keys.append(.clearLine)
                continue
            case 0x17:
                pending.removeFirst()
                keys.append(.deleteWord)
                continue
            case 0x0D, 0x0A:
                pending.removeFirst()
                keys.append(.enter)
                continue
            case 0x08, 0x7F:
                pending.removeFirst()
                keys.append(.backspace)
                continue
            case 0x09:
                pending.removeFirst()
                keys.append(.tab)
                continue
            default:
                break
            }

            if byte < 0x20 {
                pending.removeFirst()
                continue
            }

            let expected = utf8SequenceLength(byte)
            guard pending.count >= expected else { break }
            let scalarBytes = Array(pending.prefix(expected))
            pending.removeFirst(expected)
            let text = String(decoding: scalarBytes, as: UTF8.self)
            for character in text { keys.append(.character(character)) }
        }

        return keys
    }

    private func utf8SequenceLength(_ byte: UInt8) -> Int {
        if byte & 0b1111_0000 == 0b1111_0000 { return 4 }
        if byte & 0b1110_0000 == 0b1110_0000 { return 3 }
        if byte & 0b1100_0000 == 0b1100_0000 { return 2 }
        return 1
    }

    private func decodeEscape(_ buffer: [UInt8]) -> (key: TerminalKey?, consumed: Int)? {
        guard buffer.count >= 2 else { return nil }
        let introducer = buffer[1]

        if introducer == 0x1B { return (.escape, 1) }

        guard introducer == 0x5B || introducer == 0x4F else {
            return (nil, 2)
        }
        guard buffer.count >= 3 else { return nil }

        var index = 2
        var parameters = ""
        while index < buffer.count, buffer[index] >= 0x30, buffer[index] <= 0x3F {
            parameters.append(Character(UnicodeScalar(buffer[index])))
            index += 1
        }
        guard index < buffer.count else { return nil }

        let final = Character(UnicodeScalar(buffer[index]))
        let consumed = index + 1

        switch final {
        case "A": return (.up, consumed)
        case "B": return (.down, consumed)
        case "C": return (.right, consumed)
        case "D": return (.left, consumed)
        case "H": return (.home, consumed)
        case "F": return (.end, consumed)
        case "~":
            switch parameters {
            case "1", "7": return (.home, consumed)
            case "4", "8": return (.end, consumed)
            case "5": return (.pageUp, consumed)
            case "6": return (.pageDown, consumed)
            default: return (nil, consumed)
            }
        default:
            return (nil, consumed)
        }
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TerminalSize: Sendable, Hashable {
    public var rows: Int
    public var columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    public static let fallback = TerminalSize(rows: 24, columns: 80)
}

#if canImport(Darwin) || canImport(Glibc)

final class TerminalScreen: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private var savedSettings: termios?

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input
        self.output = output
    }

    var isInteractive: Bool {
        isatty(input) == 1 && isatty(output) == 1
    }

    var supportsColor: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["NO_COLOR"] != nil { return false }
        if environment["TERM"] == "dumb" { return false }
        return isatty(output) == 1
    }

    func activate() {
        var settings = termios()
        if tcgetattr(input, &settings) == 0 {
            savedSettings = settings
            var raw = settings
            cfmakeraw(&raw)
            _ = tcsetattr(input, TCSADRAIN, &raw)
        }
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
    }

    func deactivate() {
        write("\u{1B}[?25h\u{1B}[?1049l")
        if var settings = savedSettings {
            _ = tcsetattr(input, TCSADRAIN, &settings)
            savedSettings = nil
        }
    }

    func size() -> TerminalSize {
        var window = winsize()
        if ioctl(output, UInt(TIOCGWINSZ), &window) == 0,
           window.ws_row > 0, window.ws_col > 0 {
            return TerminalSize(rows: Int(window.ws_row), columns: Int(window.ws_col))
        }
        let environment = ProcessInfo.processInfo.environment
        let rows = environment["LINES"].flatMap(Int.init) ?? TerminalSize.fallback.rows
        let columns = environment["COLUMNS"].flatMap(Int.init) ?? TerminalSize.fallback.columns
        return TerminalSize(rows: rows, columns: columns)
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                #if canImport(Darwin)
                Darwin.write(output, buffer.baseAddress, buffer.count)
                #else
                Glibc.write(output, buffer.baseAddress, buffer.count)
                #endif
            }
            if written <= 0 { break }
            offset += written
        }
        bytes.removeAll()
    }

    func readChunk() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            #if canImport(Darwin)
            Darwin.read(input, pointer.baseAddress, pointer.count)
            #else
            Glibc.read(input, pointer.baseAddress, pointer.count)
            #endif
        }
        guard count > 0 else { return nil }
        return Array(buffer.prefix(count))
    }

    func waitForInput(milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }
}

#endif

import AI
import Foundation

public enum AgentTUIError: Error, CustomStringConvertible {
    case notATerminal
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .notATerminal:
            "runAgentTUI requires an interactive terminal (stdin and stdout must be a TTY)."
        case .unsupportedPlatform:
            "runAgentTUI is only available on platforms with a POSIX terminal."
        }
    }
}

public struct AgentChatTransport: ChatTransport {
    public var agent: Agent

    public init(agent: Agent) {
        self.agent = agent
    }

    public func sendMessages(
        _ request: ChatRequest
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        var messages = request.messages
        if request.trigger == .regenerateMessage {
            if let targetID = request.messageID,
               let index = messages.firstIndex(where: { $0.id == targetID }) {
                messages = Array(messages[..<index])
            } else if messages.last?.role == .assistant {
                messages.removeLast()
            }
        }

        let result = agent.stream(messages: convertToModelMessages(messages))
        return UIMessageStream.chunks(
            from: result.fullStream,
            messageID: UUID().uuidString,
            messageMetadata: { part in
                guard case .finish(_, let usage) = part else { return nil }
                return .object(["usage": .object([
                    "inputTokens": .number(Double(usage.inputTokens)),
                    "outputTokens": .number(Double(usage.outputTokens)),
                    "totalTokens": .number(Double(usage.totalTokens))
                ])])
            }
        )
    }
}

@MainActor
public func runAgentTUI(
    title: String = "Assistant",
    agent: Agent,
    tools: TerminalPartDisplayMode = .autoCollapsed,
    reasoning: TerminalPartDisplayMode = .autoCollapsed,
    responseStatistics: ResponseStatisticsMode = .outputTokensPerSecond,
    contextSize: Int? = nil,
    theme: TerminalTheme = .default
) async throws {
    try await runAgentTUI(
        title: title,
        transport: AgentChatTransport(agent: agent),
        tools: tools,
        reasoning: reasoning,
        responseStatistics: responseStatistics,
        contextSize: contextSize,
        theme: theme
    )
}

@MainActor
public func runAgentTUI(
    title: String = "Assistant",
    transport: any ChatTransport,
    tools: TerminalPartDisplayMode = .autoCollapsed,
    reasoning: TerminalPartDisplayMode = .autoCollapsed,
    responseStatistics: ResponseStatisticsMode = .outputTokensPerSecond,
    contextSize: Int? = nil,
    theme: TerminalTheme = .default
) async throws {
    #if canImport(Darwin) || canImport(Glibc)
    var model = AgentTUIModel(
        title: title,
        transcript: TerminalTranscriptOptions(tools: tools, reasoning: reasoning, theme: theme),
        responseStatistics: responseStatistics,
        contextSize: contextSize
    )
    model.status = .ready
    let runner = AgentTUIRunner(model: model, transport: transport)
    try await runner.run()
    #else
    throw AgentTUIError.unsupportedPlatform
    #endif
}

#if canImport(Darwin) || canImport(Glibc)

@MainActor
final class AgentTUIRunner {
    private enum Event: Sendable {
        case key(TerminalKey)
        case tick
    }

    private var model: AgentTUIModel
    private let transport: any ChatTransport
    private let chatID = UUID().uuidString
    private let screen = TerminalScreen()
    private let shutdown = AtomicFlag()

    private var streamTask: Task<Void, Never>?
    private var lastRows: [String] = []
    private var lastSize = TerminalSize(rows: 0, columns: 0)
    private var needsRender = true
    private var styled = true

    init(model: AgentTUIModel, transport: any ChatTransport) {
        self.model = model
        self.transport = transport
    }

    func run() async throws {
        guard screen.isInteractive else { throw AgentTUIError.notATerminal }
        styled = screen.supportsColor

        screen.activate()
        defer {
            shutdown.set()
            streamTask?.cancel()
            screen.deactivate()
        }

        let (events, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        startKeyboard(continuation)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                continuation.yield(.tick)
            }
        }
        defer {
            ticker.cancel()
            continuation.finish()
        }

        render(force: true)

        loop: for await event in events {
            switch event {
            case .key(let key):
                if handle(key) { break loop }
            case .tick:
                if model.isBusy {
                    model.spinnerFrame += 1
                    needsRender = true
                }
            }
            render()
        }
    }

    private func startKeyboard(_ continuation: AsyncStream<Event>.Continuation) {
        let screen = self.screen
        let shutdown = self.shutdown
        Thread.detachNewThread {
            var decoder = TerminalKeyDecoder()
            while !shutdown.isSet {
                guard screen.waitForInput(milliseconds: 100) else { continue }
                guard let bytes = screen.readChunk() else { break }
                for key in decoder.feed(bytes) { continuation.yield(.key(key)) }
                if decoder.hasPendingEscape, !screen.waitForInput(milliseconds: 40) {
                    for key in decoder.flushEscape() { continuation.yield(.key(key)) }
                }
            }
            continuation.finish()
        }
    }

    private func handle(_ key: TerminalKey) -> Bool {
        needsRender = true

        switch key {
        case .interrupt:
            return true

        case .escape:
            if model.isBusy {
                cancelStream()
                return false
            }
            return true

        case .repaint:
            lastRows = []

        case .enter:
            submit()

        case .character(let character):
            if let approval = model.pendingApproval, !model.isBusy {
                switch character {
                case "y", "Y":
                    respond(to: approval, approved: true)
                    return false
                case "n", "N":
                    respond(to: approval, approved: false)
                    return false
                default:
                    break
                }
            }
            model.insert(character)

        case .backspace:
            model.deleteBackward()

        case .deleteWord:
            model.deleteWord()

        case .clearLine:
            model.clearInput()

        case .left:
            model.moveCursor(by: -1)

        case .right:
            model.moveCursor(by: 1)

        case .home:
            model.moveCursorToStart()

        case .end:
            model.moveCursorToEnd()

        case .up:
            scroll(by: 1)

        case .down:
            scroll(by: -1)

        case .pageUp:
            scroll(by: viewportHeight())

        case .pageDown:
            scroll(by: -viewportHeight())

        case .tab:
            break
        }

        return false
    }

    private func viewportHeight() -> Int {
        AgentTUIRenderer.viewportHeight(model: model, size: screen.size())
    }

    private func scroll(by lines: Int) {
        let size = screen.size()
        let width = max(size.columns, 20)
        let content = AgentTUIRenderer.transcriptLines(model: model, width: width).count
        model.scroll(
            by: lines,
            viewportHeight: AgentTUIRenderer.viewportHeight(model: model, size: size),
            contentHeight: content
        )
    }

    private func submit() {
        guard !model.isBusy, model.pendingApproval == nil else { return }
        guard let text = model.takeInput() else { return }
        model.appendUserMessage(text)
        start(trigger: .submitMessage)
    }

    private func respond(to approval: PendingApproval, approved: Bool) {
        let resolved = model.respondToApproval(
            approvalID: approval.approvalID,
            approved: approved,
            reason: approved ? nil : "Denied in the terminal UI."
        )
        if resolved { start(trigger: .submitMessage) }
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        if model.isBusy { model.status = .ready }
        if let started = model.responseStartedAt {
            model.responseDuration = Date().timeIntervalSince(started)
        }
    }

    private func start(trigger: ChatTrigger) {
        streamTask?.cancel()
        model.status = .submitted
        model.responseStartedAt = Date()
        model.responseDuration = nil
        model.usage = nil
        model.scrollOffset = 0

        let request = ChatRequest(chatID: chatID, messages: model.messages, trigger: trigger)
        streamTask = Task { [transport] in
            do {
                try await consume(transport.sendMessages(request))
            } catch is CancellationError {
                model.status = .ready
            } catch {
                model.status = .error("\(error)")
            }
            needsRender = true
            render()
        }
    }

    private func consume(
        _ chunks: AsyncThrowingStream<UIMessageChunk, Error>
    ) async throws {
        var reducer = UIMessageReducer()
        var assistantIndex: Int?

        for try await chunk in chunks {
            if Task.isCancelled { break }
            reducer.apply(chunk)
            if model.status == .submitted { model.status = .streaming }

            if let index = assistantIndex {
                model.messages[index] = reducer.message
            } else {
                assistantIndex = model.messages.count
                model.messages.append(reducer.message)
            }
            if let usage = TokenUsageSummary.from(metadata: reducer.message.metadata) {
                model.usage = usage
            }
            needsRender = true
            render()
        }

        if let started = model.responseStartedAt {
            model.responseDuration = Date().timeIntervalSince(started)
        }
        if let errorText = reducer.errorText {
            model.status = .error(errorText)
        } else if !Task.isCancelled {
            model.status = .ready
        }
    }

    private func render(force: Bool = false) {
        let size = screen.size()
        var repaint = force
        if size != lastSize {
            lastSize = size
            lastRows = []
            repaint = true
            screen.write("\u{1B}[2J")
        }
        guard repaint || needsRender else { return }
        needsRender = false

        let frame = AgentTUIRenderer.frame(model: model, size: size, styled: styled)
        var output = "\u{1B}[?25l"
        for (index, row) in frame.rows.enumerated() {
            if !repaint, index < lastRows.count, lastRows[index] == row { continue }
            output += "\u{1B}[\(index + 1);1H\u{1B}[K" + row
        }
        output += "\u{1B}[\(frame.cursorRow);\(frame.cursorColumn)H\u{1B}[?25h"
        screen.write(output)
        lastRows = frame.rows
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

#endif

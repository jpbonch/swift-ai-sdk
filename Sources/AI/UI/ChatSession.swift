#if canImport(Observation)
import AI
import Foundation
import Observation

/// The only mutable owner of an open conversation.
///
/// Recovery owns history loading and stream replay as one cancellable operation.
/// Replays update stable message IDs rather than appending duplicate responses.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor
@Observable
public final class ChatSession {
    public enum Status: Sendable, Equatable {
        case ready
        case submitted
        case streaming
        case error(String)
    }

    public enum Operation: Sendable, Equatable {
        case send
        case resume
    }

    public let id: String
    public private(set) var messages: [UIMessage] = []
    public private(set) var status: Status = .ready
    public private(set) var operation: Operation?
    public private(set) var activeMessageID: String?

    public var isLoading: Bool {
        status == .submitted || status == .streaming
    }

    private let transport: any ChatTransport
    private var streamTask: Task<Void, Never>?
    private var streamToken: UUID?

    public init(transport: any ChatTransport, id: String = UUID().uuidString, messages: [UIMessage] = []) {
        self.transport = transport
        self.id = id
        self.messages = messages
    }

    /// Hydration is deliberately unavailable while a stream owns the thread.
    /// This boundary prevents a delayed database snapshot from replacing a
    /// live assistant response.
    public func hydrate(_ persisted: [UIMessage]) {
        guard !isLoading else { return }
        streamTask?.cancel()
        streamTask = nil
        streamToken = nil
        messages = persisted
        status = .ready
        operation = nil
        activeMessageID = nil
    }

    public func appendStatic(_ message: UIMessage) {
        guard !isLoading else { return }
        messages.append(message)
    }

    public func sendMessage(_ message: UIMessage, responseID: String? = nil) {
        guard !isLoading else { return }
        messages.append(message)
        if let responseID {
            messages.append(UIMessage(id: responseID, role: .assistant, parts: []))
        }
        start(
            ChatRequest(
                chatID: id,
                messages: messages,
                trigger: .submitMessage,
                messageID: responseID
            ),
            responseID: responseID
        )
    }

    public func send(_ text: String) { sendMessage(.user(text)) }

    public func setMessages(_ messages: [UIMessage]) {
        stop()
        hydrate(messages)
    }

    public func regenerate() {
        guard !isLoading else { return }
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        messages.removeAll { $0.id == lastAssistant.id }
        start(ChatRequest(
            chatID: id, messages: messages,
            trigger: .regenerateMessage, messageID: lastAssistant.id
        ))
    }

    public func addToolResult(toolCallID: String, result: JSONValue) {
        guard !isLoading else { return }
        guard let messageIndex = messages.lastIndex(where: { message in
            message.parts.contains {
                if case .tool(let tool) = $0 { return tool.toolCallID == toolCallID }
                return false
            }
        }) else { return }

        var message = messages[messageIndex]
        for (partIndex, part) in message.parts.enumerated() {
            guard case .tool(var tool) = part, tool.toolCallID == toolCallID else { continue }
            tool.state = .outputAvailable
            tool.output = result
            message.parts[partIndex] = .tool(tool)
        }
        messages[messageIndex] = message

        let stillPending = messages[messageIndex].parts.contains {
            if case .tool(let tool) = $0 { return tool.state == .inputAvailable }
            return false
        }
        if !stillPending {
            start(ChatRequest(chatID: id, messages: messages, trigger: .submitMessage))
        }
    }

    public func addToolApprovalResponse(
        approvalID: String, approved: Bool, reason: String? = nil
    ) {
        guard !isLoading else { return }
        guard let messageIndex = messages.lastIndex(where: { message in
            message.parts.contains {
                if case .tool(let tool) = $0 { return tool.approval?.id == approvalID }
                return false
            }
        }) else { return }

        var message = messages[messageIndex]
        for (partIndex, part) in message.parts.enumerated() {
            guard case .tool(var tool) = part, tool.approval?.id == approvalID else { continue }
            tool.state = .approvalResponded
            tool.approval = ToolApproval(
                id: approvalID,
                approved: approved,
                reason: reason,
                isAutomatic: tool.approval?.isAutomatic,
                signature: tool.approval?.signature
            )
            message.parts[partIndex] = .tool(tool)
        }
        messages[messageIndex] = message

        let stillPending = messages[messageIndex].parts.contains {
            if case .tool(let tool) = $0 { return tool.state == .approvalRequested }
            return false
        }
        if !stillPending {
            start(ChatRequest(chatID: id, messages: messages, trigger: .submitMessage))
        }
    }


    private func start(_ request: ChatRequest) {
        start(request, responseID: request.messageID)
    }

    public func resumeStream() {
        guard !isLoading else { return }
        streamTask?.cancel()
        let token = UUID()
        streamToken = token
        status = .submitted
        operation = .resume

        streamTask = Task { [transport] in
            do {
                guard let chunks = try await transport.reconnectToStream(chatID: id) else {
                    finish(token: token)
                    return
                }
                try await consume(
                    chunks,
                    expectedResponseID: nil,
                    replaying: true,
                    token: token
                )
            } catch is CancellationError {
                finish(token: token)
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Reconcile persisted history and reconnect after suspension or a lost
    /// connection. Cancels only local consumption, never the server generation.
    /// New sends, clear, or setMessages invalidate any outstanding recovery.
    public func recover() {
        stop()
        let token = UUID()
        streamToken = token
        status = .submitted
        operation = .resume
        streamTask = Task { [transport] in
            do {
                let persisted = try await transport.loadMessages(chatID: id)
                guard streamToken == token else { return }
                if let persisted { reconcile(persisted) }
                if let chunks = try await transport.reconnectToStream(chatID: id) {
                    try await consume(chunks, expectedResponseID: nil, replaying: true, token: token, finalize: false)
                    guard streamToken == token else { return }
                }
                if activeMessageID == nil {
                    // The generation may have finished between the history
                    // fetch and reconnect check. Read its final persisted reply.
                    let completed = try await transport.loadMessages(chatID: id)
                    guard streamToken == token else { return }
                    if let completed { reconcile(completed) }
                }
                finish(token: token)
            } catch {
                fail(error, token: token)
            }
        }
    }

    private func reconcile(_ persisted: [UIMessage]) {
        // A persisted snapshot can lag a partial response already on screen.
        // Replay will replace it once the server catches up.
        let visible = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        messages = persisted.map { saved in
            guard let current = visible[saved.id],
                  messageProgress(current) > messageProgress(saved) else { return saved }
            return current
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        streamToken = nil
        finish()
    }

    public func clear() {
        streamTask?.cancel()
        streamTask = nil
        streamToken = nil
        messages = []
        finish()
    }

    private func start(_ request: ChatRequest, responseID: String?) {
        streamTask?.cancel()
        let token = UUID()
        streamToken = token
        status = .submitted
        operation = .send
        activeMessageID = responseID

        streamTask = Task { [transport] in
            do {
                try await consume(
                    transport.sendMessages(request),
                    expectedResponseID: responseID,
                    replaying: false,
                    token: token
                )
            } catch is CancellationError {
                finish(token: token)
            } catch {
                fail(error, token: token)
            }
        }
    }

    private func consume(
        _ chunks: AsyncThrowingStream<UIMessageChunk, Error>,
        expectedResponseID: String?,
        replaying: Bool,
        token: UUID,
        finalize: Bool = true
    ) async throws {
        var reducer = UIMessageReducer(messageID: expectedResponseID ?? UUID().uuidString)
        var resolvedResponseID = expectedResponseID
        var targetIndex = expectedResponseID.flatMap { responseID in
            messages.firstIndex { $0.id == responseID && $0.role == .assistant }
        }
        var replayFloor = targetIndex.map { messageProgress(messages[$0]) } ?? 0

        for try await chunk in chunks {
            try Task.checkCancellation()
            guard streamToken == token else { throw CancellationError() }

            if case .start(let messageID, _) = chunk, let messageID {
                if let resolvedResponseID, resolvedResponseID != messageID {
                    throw StreamContractError.changedResponseID
                }
                resolvedResponseID = messageID
            } else if resolvedResponseID == nil && replaying {
                // A follower has no safe target without the durable response
                // ID. Reject an old or malformed stream before it can mutate
                // an arbitrary assistant row.
                throw StreamContractError.missingResponseID
            }

            reducer.apply(chunk)
            if resolvedResponseID == nil && !replaying {
                resolvedResponseID = reducer.message.id
            }
            if status == .submitted { status = .streaming }
            guard let responseID = resolvedResponseID else { continue }

            if targetIndex == nil || messages[targetIndex!].id != responseID {
                if let existing = messages.firstIndex(where: {
                    $0.id == responseID && $0.role == .assistant
                }) {
                    targetIndex = existing
                    replayFloor = replaying ? messageProgress(messages[existing]) : 0
                } else {
                    targetIndex = messages.count
                    messages.append(reducer.message)
                    replayFloor = 0
                }
            }

            activeMessageID = responseID
            guard let targetIndex else { continue }

            // Followers replay buffered chunks from the beginning. Keep the
            // already-visible partial response until the replay catches up so
            // reconnecting cannot make text shrink and regenerate.
            if !replaying || messageProgress(reducer.message) >= replayFloor {
                messages[targetIndex] = reducer.message
            }
        }

        if let errorText = reducer.errorText {
            guard streamToken == token else { return }
            status = .error(errorText)
            operation = nil
            streamTask = nil
            streamToken = nil
            return
        }
        if finalize { finish(token: token) }
    }

    private func finish(token: UUID? = nil) {
        if let token, streamToken != token { return }
        status = .ready
        operation = nil
        activeMessageID = nil
        streamTask = nil
        streamToken = nil
    }

    private func fail(_ error: Error, token: UUID) {
        guard streamToken == token else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            finish(token: token)
            return
        }
        status = .error(error.localizedDescription)
        operation = nil
        streamTask = nil
        streamToken = nil
    }

    private func messageProgress(_ message: UIMessage) -> Int {
        message.parts.reduce(into: 0) { result, part in
            switch part {
            case .text(let value):
                result += value.text.utf8.count
            case .reasoning(let value):
                result += value.text.utf8.count
            case .tool(let value):
                result += value.toolName.utf8.count + value.toolCallID.utf8.count
                result += encodedSize(value.input) + encodedSize(value.output)
                result += value.errorText?.utf8.count ?? 0
            case .data(let value):
                result += value.name.utf8.count + encodedSize(value.data)
            case .sourceURL(let value):
                result += value.url.utf8.count
            case .sourceDocument(let value):
                result += value.title.utf8.count
            case .file(let value):
                result += value.url.utf8.count
            case .stepStart:
                result += 1
            }
        }
    }

    private func encodedSize(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        return (try? JSONEncoder().encode(value).count) ?? 0
    }
}

private enum StreamContractError: LocalizedError {
    case missingResponseID
    case changedResponseID

    var errorDescription: String? {
        switch self {
        case .missingResponseID:
            "The resumed response did not identify its message."
        case .changedResponseID:
            "The response changed identity while streaming."
        }
    }
}

#endif

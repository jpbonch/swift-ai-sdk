import AI
import Foundation
import XCTest

final class ChatSessionTests: XCTestCase {
    @MainActor
    func testDefaultSendAcceptsServerAssignedResponseID() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        store.send("Hello")
        let stream = try await transport.awaitSendStream()
        stream.yield(.start(messageID: "server-response"))
        stream.finish()
        try await settle(store)
        XCTAssertEqual(store.messages.last?.id, "server-response")
        XCTAssertEqual(store.status, .ready)
    }

    @MainActor
    func testCompletionBetweenHistoryAndReconnectIsRecovered() async throws {
        let store = ChatSession(transport: FinishingTransport())
        store.recover()
        try await settle(store)
        XCTAssertEqual(store.messages.last?.text, "Final reply")
    }
    @MainActor
    func testRecoveryLoadsReplyCompletedWhileDisconnected() async throws {
        let store = ChatSession(transport: SavedTransport(), messages: [.user("Hello", id: "u")])
        store.recover()
        try await settle(store)
        XCTAssertEqual(store.messages.map(\.id), ["u", "a"])
        XCTAssertEqual(store.messages.last?.text, "Finished while away")
    }

    @MainActor
    func testClearInvalidatesDelayedRecovery() async throws {
        let transport = DelayedHistoryTransport()
        let store = ChatSession(transport: transport)
        store.recover()
        await transport.waitUntilLoading()
        store.clear()
        await transport.finishLoading()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.status, .ready)
    }

    @MainActor
    func testNewSendInvalidatesDelayedRecovery() async throws {
        let transport = DelayedHistoryTransport()
        let store = ChatSession(transport: transport)
        store.recover()
        await transport.waitUntilLoading()
        store.stop()
        store.sendMessage(.user("New question"), responseID: "new")
        await transport.finishLoading()
        try await settle(store)
        XCTAssertEqual(store.messages.last?.id, "new")
        XCTAssertFalse(store.messages.contains(where: { $0.id == "stale" }))
    }
    @MainActor
    func testSendingStreamsIntoOneStableResponse() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        let responseID = UUID().uuidString

        store.sendMessage(.user("Hello"), responseID: responseID)
        let stream = try await transport.awaitSendStream()
        stream.yield(.start(messageID: responseID))
        stream.yield(.textStart(id: "text-0"))
        stream.yield(.textDelta(id: "text-0", delta: "Hello back"))
        stream.yield(.textEnd(id: "text-0"))
        stream.finish()
        try await settle(store)

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.id, responseID)
        XCTAssertEqual(store.messages.last?.text, "Hello back")
        XCTAssertEqual(store.status, .ready)
    }

    @MainActor
    func testStreamedTaskLinkStaysOnTheAssistantResponse() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        let responseID = UUID().uuidString

        store.sendMessage(.user("Start a task"), responseID: responseID)
        let stream = try await transport.awaitSendStream()
        stream.yield(.start(messageID: responseID))
        stream.yield(.data(
            name: "task-link",
            id: "task-123",
            data: [
                "taskId": .string("task-123"),
                "title": .string("Check inventory"),
                "status": .string("running"),
            ]
        ))
        stream.yield(.textStart(id: "text-0"))
        stream.yield(.textDelta(id: "text-0", delta: "I started the inventory check."))
        stream.yield(.textEnd(id: "text-0"))
        stream.finish()
        try await settle(store)

        XCTAssertEqual(store.messages.last?.id, responseID)
        XCTAssertEqual(store.messages.last?.parts.count, 2)
        guard case .data(let taskLink) = store.messages.last?.parts.first else {
            return XCTFail("Expected the streamed task link to remain attached")
        }
        XCTAssertEqual(taskLink.name, "task-link")
        XCTAssertEqual(taskLink.data["taskId"]?.stringValue, "task-123")
        XCTAssertEqual(taskLink.data["title"]?.stringValue, "Check inventory")
        XCTAssertEqual(store.messages.last?.text, "I started the inventory check.")
    }

    @MainActor
    func testReconnectReplayCannotShrinkOrDuplicatePersistedResponse() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        let oldID = UUID().uuidString
        let responseID = UUID().uuidString
        let visiblePrefix = "This is the latest partial response already visible."
        store.hydrate([
            .assistant("The older JLCPCB response", id: oldID),
            .user("What is new?"),
            .assistant(visiblePrefix, id: responseID),
        ])

        store.resumeStream()
        let stream = try await transport.awaitReconnectStream()
        stream.yield(.start(messageID: responseID))
        stream.yield(.textStart(id: "text-0"))
        stream.yield(.textDelta(id: "text-0", delta: "This is the latest"))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.messages.last?.text, visiblePrefix)
        XCTAssertEqual(store.messages.filter { $0.id == responseID }.count, 1)
        XCTAssertEqual(store.messages.first?.text, "The older JLCPCB response")

        stream.yield(.textDelta(
            id: "text-0",
            delta: " partial response already visible. Now it is complete."
        ))
        stream.yield(.textEnd(id: "text-0"))
        stream.finish()
        try await settle(store)

        XCTAssertEqual(store.messages.last?.text, "\(visiblePrefix) Now it is complete.")
        XCTAssertEqual(store.messages.filter { $0.id == responseID }.count, 1)
        XCTAssertEqual(store.messages.first?.text, "The older JLCPCB response")
    }

    @MainActor
    func testUnidentifiedReplayCannotMutateAnyMessage() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        let original = UIMessage.assistant("Keep me", id: UUID().uuidString)
        store.hydrate([original])

        store.resumeStream()
        let stream = try await transport.awaitReconnectStream()
        stream.yield(.textStart(id: "text-0"))
        stream.yield(.textDelta(id: "text-0", delta: "Wrong response"))
        stream.finish()
        try await settle(store)

        XCTAssertEqual(store.messages, [original])
        guard case .error = store.status else {
            return XCTFail("An unidentified replay should fail closed")
        }
    }

    @MainActor
    func testCancelledStreamCannotResetTheNextSend() async throws {
        let transport = ManualTransport()
        let store = ChatSession(transport: transport)
        let firstResponseID = UUID().uuidString
        let secondResponseID = UUID().uuidString

        store.sendMessage(.user("First"), responseID: firstResponseID)
        let firstStream = try await transport.awaitSendStream()
        store.stop()

        store.sendMessage(.user("Second"), responseID: secondResponseID)
        let secondStream = try await transport.awaitSendStream()
        firstStream.finish()
        await Task.yield()

        XCTAssertTrue(store.isLoading)
        XCTAssertEqual(store.activeMessageID, secondResponseID)

        secondStream.yield(.start(messageID: secondResponseID))
        secondStream.yield(.textStart(id: "text-0"))
        secondStream.yield(.textDelta(id: "text-0", delta: "Second reply"))
        secondStream.yield(.textEnd(id: "text-0"))
        secondStream.finish()
        try await settle(store)

        XCTAssertEqual(store.messages.last?.id, secondResponseID)
        XCTAssertEqual(store.messages.last?.text, "Second reply")
    }

    @MainActor
    private func settle(_ store: ChatSession) async throws {
        for _ in 0 ..< 200 where store.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isLoading)
    }
}

private final class ManualTransport: ChatTransport, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<UIMessageChunk, Error>.Continuation

    private let lock = NSLock()
    private var sendContinuation: Continuation?
    private var reconnectContinuation: Continuation?

    func sendMessages(
        _ request: ChatRequest
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { sendContinuation = continuation }
        }
    }

    func reconnectToStream(
        chatID: String
    ) async throws -> AsyncThrowingStream<UIMessageChunk, Error>? {
        AsyncThrowingStream { continuation in
            lock.withLock { reconnectContinuation = continuation }
        }
    }

    func awaitSendStream() async throws -> Continuation {
        try await continuation {
            lock.withLock {
                defer { sendContinuation = nil }
                return sendContinuation
            }
        }
    }

    func awaitReconnectStream() async throws -> Continuation {
        try await continuation {
            lock.withLock {
                defer { reconnectContinuation = nil }
                return reconnectContinuation
            }
        }
    }

    private func continuation(_ read: () -> Continuation?) async throws -> Continuation {
        for _ in 0 ..< 200 {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Timeout()
    }
}

private struct Timeout: Error {}

private struct SavedTransport: ChatTransport {
    func loadMessages(chatID: String) async throws -> [UIMessage]? {
        [.user("Hello", id: "u"), .assistant("Finished while away", id: "a")]
    }
    func sendMessages(_ request: ChatRequest) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor FinishingTransport: ChatTransport {
    var reads = 0
    func loadMessages(chatID: String) async throws -> [UIMessage]? {
        reads += 1
        return reads == 1 ? [.user("Hello")] : [.assistant("Final reply", id: "done")]
    }
    func reconnectToStream(chatID: String) async throws -> AsyncThrowingStream<UIMessageChunk, Error>? {
        AsyncThrowingStream { $0.finish() }
    }
    func sendMessages(_ request: ChatRequest) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor DelayedHistoryTransport: ChatTransport {
    var continuation: CheckedContinuation<[UIMessage]?, Never>?
    func loadMessages(chatID: String) async throws -> [UIMessage]? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilLoading() async {
        while continuation == nil { await Task.yield() }
    }
    func finishLoading() {
        continuation?.resume(returning: [.assistant("Stale", id: "stale")])
        continuation = nil
    }
    func sendMessages(_ request: ChatRequest) async throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        AsyncThrowingStream {
            $0.yield(.start(messageID: request.messageID))
            $0.finish()
        }
    }
}

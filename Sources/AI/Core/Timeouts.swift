import Foundation

public enum TimeoutScope: String, Sendable, Hashable {
    case total
    case step
    case firstChunk
    case chunk
    case tool
}

public struct GenerationTimeout: Sendable, Hashable {
    public var total: Duration?
    public var step: Duration?
    public var firstChunk: Duration?
    public var chunk: Duration?
    public var tool: Duration?
    public var tools: [String: Duration]

    public init(
        total: Duration? = nil,
        step: Duration? = nil,
        firstChunk: Duration? = nil,
        chunk: Duration? = nil,
        tool: Duration? = nil,
        tools: [String: Duration] = [:]
    ) {
        self.total = total
        self.step = step
        self.firstChunk = firstChunk
        self.chunk = chunk
        self.tool = tool
        self.tools = tools
    }

    public static func after(_ duration: Duration) -> GenerationTimeout {
        GenerationTimeout(total: duration)
    }

    public func limit(forTool name: String) -> Duration? {
        tools[name] ?? tool
    }

    public var watchesStream: Bool {
        step != nil || firstChunk != nil || chunk != nil
    }

    public var isEmpty: Bool {
        total == nil && tool == nil && tools.isEmpty && !watchesStream
    }
}

func withTimeout<T: Sendable>(
    _ duration: Duration?,
    scope: TimeoutScope,
    tool: String? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let duration else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw AIError.timedOut(scope: scope, limit: duration, tool: tool)
        }
        guard let result = try await group.next() else {
            throw AIError.timedOut(scope: scope, limit: duration, tool: tool)
        }
        group.cancelAll()
        return result
    }
}

enum StreamTimeout {

    static func isContent(_ part: StreamPart) -> Bool {
        switch part {
        case .textDelta(let text): !text.isEmpty
        case .reasoningDelta(let text): !text.isEmpty
        case .toolArgumentsDelta(_, let partialJSON): !partialJSON.isEmpty
        case .toolCall, .toolResult, .source: true
        case .toolCallStart, .providerMetadata, .finish: false
        }
    }

    static func guarded(
        _ source: AsyncThrowingStream<StreamPart, Error>,
        timeout: GenerationTimeout?
    ) -> AsyncThrowingStream<StreamPart, Error> {
        guard let timeout, timeout.watchesStream else { return source }

        return AsyncThrowingStream { continuation in
            let monitor = StallMonitor()
            let started = ContinuousClock.now

            let pump = Task {
                do {
                    for try await part in source {
                        if isContent(part) { await monitor.markContent() }
                        continuation.yield(part)
                    }
                    await monitor.finish()
                    continuation.finish()
                } catch {
                    await monitor.finish()
                    continuation.finish(throwing: error)
                }
            }

            let watchdog = Task {
                while !Task.isCancelled {
                    let snapshot = await monitor.snapshot()
                    if snapshot.isFinished { return }

                    // The step limit is wall clock on the whole step, so it is
                    // due the moment it passes. The stall limits are only due
                    // when nothing has arrived since they were measured.
                    var deadlines: [(Duration, ContinuousClock.Instant, TimeoutScope, Bool)] = []
                    if let step = timeout.step {
                        deadlines.append((step, started.advanced(by: step), .step, false))
                    }
                    let stall = snapshot.sawContent ? timeout.chunk : timeout.firstChunk
                    if let stall {
                        deadlines.append((
                            stall,
                            snapshot.lastContent.advanced(by: stall),
                            snapshot.sawContent ? .chunk : .firstChunk,
                            true
                        ))
                    }

                    // Nothing left that can ever fire — waking up to re-check
                    // would just burn the rest of the stream.
                    guard let next = deadlines.min(by: { $0.1 < $1.1 }) else { return }

                    let now = ContinuousClock.now
                    if now < next.1 {
                        do {
                            try await Task.sleep(for: next.1 - now)
                        } catch {
                            return
                        }
                        continue
                    }

                    let fresh = await monitor.snapshot()
                    if fresh.isFinished { return }
                    let stalled = fresh.lastContent == snapshot.lastContent
                        && fresh.sawContent == snapshot.sawContent
                    if !next.3 || stalled {
                        pump.cancel()
                        continuation.finish(throwing: AIError.timedOut(
                            scope: next.2, limit: next.0, tool: nil
                        ))
                        return
                    }
                }
            }

            continuation.onTermination = { _ in
                pump.cancel()
                watchdog.cancel()
            }
        }
    }
}

actor StallMonitor {
    struct Snapshot: Sendable {
        var lastContent: ContinuousClock.Instant
        var sawContent: Bool
        var isFinished: Bool
    }

    private var lastContent = ContinuousClock.now
    private var sawContent = false
    private var isFinished = false

    func markContent() {
        lastContent = .now
        sawContent = true
    }

    func finish() {
        isFinished = true
    }

    func snapshot() -> Snapshot {
        Snapshot(lastContent: lastContent, sawContent: sawContent, isFinished: isFinished)
    }
}

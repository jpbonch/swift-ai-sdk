import XCTest
@testable import AI
import AITesting

final class TimeoutTests: XCTestCase {

    func testWithTimeoutReturnsFastResults() async throws {
        let value = try await withTimeout(.milliseconds(500), scope: .total) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWithTimeoutThrowsWhenSlow() async {
        do {
            _ = try await withTimeout(.milliseconds(30), scope: .total) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
            XCTFail("expected a timeout")
        } catch let error as AIError {
            guard case .timedOut(let scope, _, let tool) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(scope, .total)
            XCTAssertNil(tool)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }

    func testNilTimeoutNeverFires() async throws {
        let value = try await withTimeout(nil, scope: .step) { "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testOnlyContentBearingChunksSatisfyStallTimeouts() {
        XCTAssertTrue(StreamTimeout.isContent(.textDelta("hi")))
        XCTAssertTrue(StreamTimeout.isContent(.reasoningDelta("think")))
        XCTAssertTrue(StreamTimeout.isContent(.toolArgumentsDelta(id: "c1", partialJSON: "{")))
        XCTAssertTrue(StreamTimeout.isContent(
            .toolCall(ToolCall(id: "c1", name: "t", arguments: [:]))
        ))

        XCTAssertFalse(StreamTimeout.isContent(.textDelta("")))
        XCTAssertFalse(StreamTimeout.isContent(.reasoningDelta("")))
        XCTAssertFalse(StreamTimeout.isContent(.toolArgumentsDelta(id: "c1", partialJSON: "")))
        XCTAssertFalse(StreamTimeout.isContent(.toolCallStart(id: "c1", name: "t")))
        XCTAssertFalse(StreamTimeout.isContent(.providerMetadata(.object([:]))))
        XCTAssertFalse(StreamTimeout.isContent(
            .finish(reason: .stop, usage: Usage())
        ))
    }

    func testFirstChunkTimeoutFiresWhenTheModelStallsBeforeContent() async {
        let model = MockLanguageModel(chunkDelay: .milliseconds(400), parts: [
            .textDelta("late"),
            .finish(reason: .stop, usage: Usage())
        ])
        let result = streamText(
            model: model,
            prompt: "hi",
            timeout: GenerationTimeout(firstChunk: .milliseconds(60))
        )

        do {
            for try await _ in result.textStream {}
            XCTFail("expected a first-chunk timeout")
        } catch let error as AIError {
            guard case .timedOut(let scope, _, _) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(scope, .firstChunk)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }

    func testProviderMetadataDoesNotResetTheFirstChunkTimeout() async {
        let model = MockLanguageModel(chunkDelay: .milliseconds(120), parts: [
            .providerMetadata(.object(["keepalive": .bool(true)])),
            .providerMetadata(.object(["keepalive": .bool(true)])),
            .providerMetadata(.object(["keepalive": .bool(true)])),
            .textDelta("finally"),
            .finish(reason: .stop, usage: Usage())
        ])
        let result = streamText(
            model: model,
            prompt: "hi",
            timeout: GenerationTimeout(firstChunk: .milliseconds(200))
        )

        do {
            for try await _ in result.textStream {}
            XCTFail("expected a first-chunk timeout despite metadata traffic")
        } catch let error as AIError {
            guard case .timedOut(let scope, _, _) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(scope, .firstChunk)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }

    func testStreamsThatKeepProducingContentAreNotTimedOut() async throws {
        let model = MockLanguageModel(chunkDelay: .milliseconds(20), parts: [
            .textDelta("a"), .textDelta("b"), .textDelta("c"),
            .finish(reason: .stop, usage: Usage())
        ])
        let result = streamText(
            model: model,
            prompt: "hi",
            timeout: GenerationTimeout(firstChunk: .milliseconds(300), chunk: .milliseconds(300))
        )

        var text = ""
        for try await delta in result.textStream { text += delta }
        XCTAssertEqual(text, "abc")
    }

    func testToolTimeoutBecomesAToolErrorTheModelCanSee() async throws {
        let slow = Tool(
            name: "slow",
            description: "Sleeps.",
            parameters: ["type": "object"]
        ) { _ in
            try await Task.sleep(for: .seconds(5))
            return .string("never")
        }

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "slow", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [
                .textDelta("gave up"),
                .finish(reason: .stop, usage: Usage())
            ]
        ])

        let result = try await generateText(
            model: model,
            prompt: "go",
            tools: [slow],
            timeout: GenerationTimeout(tool: .milliseconds(50))
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertTrue(result.toolResults[0].isError)
        XCTAssertTrue(
            result.toolResults[0].output.stringValue?.contains("slow") == true,
            "\(result.toolResults[0].output)"
        )
        XCTAssertEqual(result.text, "gave up")
    }

    func testPerToolTimeoutOverridesTheDefault() async throws {
        let fast = Tool(
            name: "fast", description: "Quick.", parameters: ["type": "object"]
        ) { _ in .string("done") }

        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "fast", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("ok"), .finish(reason: .stop, usage: Usage())]
        ])

        let timeout = GenerationTimeout(
            tool: .nanoseconds(1), tools: ["fast": .seconds(5)]
        )
        XCTAssertEqual(timeout.limit(forTool: "fast"), .seconds(5))
        XCTAssertEqual(timeout.limit(forTool: "other"), .nanoseconds(1))

        let result = try await generateText(
            model: model, prompt: "go", tools: [fast], timeout: timeout
        )
        XCTAssertFalse(result.toolResults[0].isError)
        XCTAssertEqual(result.toolResults[0].output.stringValue, "done")
    }

    func testTotalTimeoutAbortsAMultiStepRun() async {
        let slow = Tool(
            name: "slow", description: "Sleeps.", parameters: ["type": "object"]
        ) { _ in
            try await Task.sleep(for: .milliseconds(300))
            return .string("done")
        }
        let model = MockLanguageModel(responses: [
            [
                .toolCall(ToolCall(id: "c1", name: "slow", arguments: [:])),
                .finish(reason: .toolCalls, usage: Usage())
            ],
            [.textDelta("never"), .finish(reason: .stop, usage: Usage())]
        ])

        do {
            _ = try await generateText(
                model: model, prompt: "go", tools: [slow],
                timeout: GenerationTimeout(total: .milliseconds(80))
            )
            XCTFail("expected a total timeout")
        } catch let error as AIError {
            guard case .timedOut(let scope, _, _) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(scope, .total)
        } catch {
            XCTFail("expected AIError, got \(error)")
        }
    }

    func testTimeoutShorthandAndEmptiness() {
        XCTAssertEqual(GenerationTimeout.after(.seconds(5)).total, .seconds(5))
        XCTAssertTrue(GenerationTimeout().isEmpty)
        XCTAssertFalse(GenerationTimeout(chunk: .seconds(1)).isEmpty)
        XCTAssertTrue(GenerationTimeout(step: .seconds(1)).watchesStream)
        XCTAssertFalse(GenerationTimeout(tool: .seconds(1)).watchesStream)
    }
}

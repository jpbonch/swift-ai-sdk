import AITesting
import XCTest
@testable import AI

final class CompactionSalienceTests: XCTestCase {

    private func plan(
        _ messages: [Message],
        pinning: CompactionPinning = .default,
        keepLastSteps: Int = 2,
        idempotent: Set<String> = []
    ) -> ContextCompactor.Plan {
        ContextCompactor.Plan(
            messages: messages,
            settings: Compaction(pinning: pinning, keepLastSteps: keepLastSteps),
            idempotentTools: idempotent
        )
    }

    func testFirstUserMessageIsPinnedNotCompressed() {
        let messages: [Message] = [
            .user("Port the xAI collections client and keep the management key separate."),
            .assistant("Looking at the current client."),
            .user("Any update?"),
            .assistant("Still working.")
        ]
        let result = plan(messages)

        XCTAssertTrue(result.pinned.contains { $0.text.contains("Port the xAI collections client") })
        XCTAssertFalse(result.compressible.contains { $0.text.contains("Port the xAI collections client") })
    }

    func testSystemMessagesAreAlwaysPinned() {
        let messages: [Message] = [
            .system("You never add code comments."),
            .user("Start"),
            .assistant("ok"),
            .user("continue"),
            .assistant("done")
        ]
        let result = plan(messages)
        XCTAssertTrue(result.pinned.contains { $0.role == .system })
        XCTAssertFalse(result.compressible.contains { $0.role == .system })
    }

    func testFailedToolResultsArePinned() {
        let failure = Message(role: .tool, content: [.toolResult(ToolResult(
            toolCallID: "1", name: "build", output: .string("linker error"), isError: true
        ))])
        let messages: [Message] = [
            .user("Fix the build"),
            failure,
            .assistant("Trying another approach"),
            .user("go on"),
            .assistant("ok")
        ]
        let result = plan(messages)
        XCTAssertTrue(result.pinned.contains { ContextCompactor.carriesError($0) })
    }

    func testErrorPinningCanBeDisabled() {
        let failure = Message(role: .tool, content: [.toolResult(ToolResult(
            toolCallID: "1", name: "build", output: .string("linker error"), isError: true
        ))])
        let messages: [Message] = [
            .user("Fix the build"), failure, .assistant("a"), .user("b"), .assistant("c")
        ]
        let result = plan(messages, pinning: [.firstUserMessage])
        XCTAssertFalse(result.pinned.contains { ContextCompactor.carriesError($0) })
    }

    func testLastStepsStayInTheWorkingSetVerbatim() {
        let messages: [Message] = (0..<6).map { .assistant("step \($0)") }
        let result = plan(messages, pinning: [], keepLastSteps: 2)

        XCTAssertEqual(result.workingSet.count, 2)
        XCTAssertEqual(result.workingSet.first?.text, "step 4")
        XCTAssertEqual(result.workingSet.last?.text, "step 5")
    }

    func testLiveReferenceKeepsAnOlderMessageThatTheWorkingSetStillMentions() {
        let messages: [Message] = [
            .user("Start the migration"),
            .assistant("Read Sources/AI/MCP/MCPOAuth.swift and it defines the token store."),
            .assistant("Unrelated aside about the weather."),
            .assistant("Now editing Sources/AI/MCP/MCPOAuth.swift again."),
            .assistant("Continuing.")
        ]
        let result = plan(messages, keepLastSteps: 2)

        XCTAssertTrue(
            result.pinned.contains { $0.text.contains("defines the token store") },
            "the older message shares an identifier with the working set, so it is live"
        )
        XCTAssertTrue(
            result.compressible.contains { $0.text.contains("weather") },
            "the aside shares no identifier and should be compressible"
        )
    }

    func testIdempotentToolResultsBecomePointers() {
        let big = String(repeating: "x", count: 4000)
        let messages: [Message] = [
            .user("Read the file"),
            Message(role: .tool, content: [.toolResult(ToolResult(
                toolCallID: "1", name: "read_file", output: .string(big)
            ))]),
            .assistant("a"), .assistant("b")
        ]
        let result = plan(messages, pinning: [], keepLastSteps: 2, idempotent: ["read_file"])

        XCTAssertEqual(result.pointerizedTools, ["read_file"])
        let rendered = ContextCompactor.describe(result.compressible)
        XCTAssertFalse(rendered.contains(big))
        XCTAssertTrue(rendered.contains("re-run the tool"))
    }

    func testNonIdempotentToolResultsAreKeptVerbatim() {
        let body = String(repeating: "y", count: 2000)
        let messages: [Message] = [
            .user("Charge the card"),
            Message(role: .tool, content: [.toolResult(ToolResult(
                toolCallID: "1", name: "create_payment", output: .string(body)
            ))]),
            .assistant("a"), .assistant("b")
        ]
        let result = plan(messages, pinning: [], keepLastSteps: 2, idempotent: ["read_file"])

        XCTAssertTrue(result.pointerizedTools.isEmpty)
        XCTAssertTrue(ContextCompactor.describe(result.compressible).contains(body))
    }

    func testToolCallSignatureSurvivesEvenWhenTheResultIsPointerized() {
        let messages: [Message] = [
            .user("go"),
            Message(role: .assistant, content: [.toolCall(ToolCall(
                id: "1", name: "search", arguments: .object(["q": .string("MCPOAuthSession")])
            ))]),
            Message(role: .tool, content: [.toolResult(ToolResult(
                toolCallID: "1", name: "search", output: .string(String(repeating: "z", count: 3000))
            ))]),
            .assistant("a"), .assistant("b")
        ]
        let result = plan(messages, pinning: [], keepLastSteps: 2, idempotent: ["search"])
        let rendered = ContextCompactor.describe(result.compressible)

        XCTAssertTrue(rendered.contains("called search"))
        XCTAssertTrue(rendered.contains("MCPOAuthSession"))
    }
}

final class CompactionBudgetTests: XCTestCase {

    func testBudgetSplitsTheContextWindow() {
        let budget = CompactionBudget(contextWindow: 200_000, workingSet: 0.5, compacted: 0.2)
        XCTAssertEqual(budget.workingSetTokens(window: 200_000), 100_000)
        XCTAssertEqual(budget.compactedTokens(window: 200_000), 40_000)
    }

    func testBudgetDerivesTheWindowFromTheModelWhenUnset() {
        let budget = CompactionBudget(workingSet: 0.5)
        let opus = MockLanguageModel(modelID: "claude-opus-5", parts: [])
        let haiku = MockLanguageModel(modelID: "claude-haiku-4-5", parts: [])

        XCTAssertEqual(budget.contextWindow(for: opus), 1_000_000)
        XCTAssertEqual(budget.workingSetTokens(for: opus), 500_000)
        XCTAssertEqual(budget.contextWindow(for: haiku), 200_000)
        XCTAssertEqual(budget.workingSetTokens(for: haiku), 100_000)
    }

    func testAnExplicitWindowOverridesTheModel() {
        let budget = CompactionBudget(contextWindow: 32_000)
        let opus = MockLanguageModel(modelID: "claude-opus-5", parts: [])
        XCTAssertEqual(budget.contextWindow(for: opus), 32_000)
    }

    func testShortHistoryDoesNotTriggerCompaction() {
        let messages: [Message] = [.user("hello"), .assistant("hi")]
        XCTAssertFalse(
            ContextCompactor.shouldCompact(
                messages, budget: CompactionBudget(), window: 200_000
            )
        )
    }

    func testHistoryOverTheWorkingSetBudgetTriggersCompaction() {
        let messages: [Message] = [.user(String(repeating: "a", count: 40_000))]
        let budget = CompactionBudget(workingSet: 0.5)
        XCTAssertTrue(ContextCompactor.shouldCompact(messages, budget: budget, window: 10_000))
    }

    func testTheSameHistoryTriggersOnHaikuButNotOpus() {
        let messages: [Message] = [.user(String(repeating: "a", count: 600_000))]
        let budget = CompactionBudget(workingSet: 0.5)
        let opus = MockLanguageModel(modelID: "claude-opus-5", parts: [])
        let haiku = MockLanguageModel(modelID: "claude-haiku-4-5", parts: [])

        XCTAssertTrue(ContextCompactor.shouldCompact(
            messages, budget: budget, window: budget.contextWindow(for: haiku)
        ))
        XCTAssertFalse(ContextCompactor.shouldCompact(
            messages, budget: budget, window: budget.contextWindow(for: opus)
        ))
    }

    func testEstimateCountsToolResultPayloads() {
        let empty = ContextCompactor.estimateTokens([.assistant("")])
        let heavy = ContextCompactor.estimateTokens([
            Message(role: .tool, content: [.toolResult(ToolResult(
                toolCallID: "1", name: "read", output: .string(String(repeating: "x", count: 4000))
            ))])
        ])
        XCTAssertGreaterThan(heavy, empty + 900)
    }

    func testCompactIsSkippedWhenUnderBudget() async throws {
        let model = MockLanguageModel(parts: [])
        let outcome = try await ContextCompactor.compact(
            [.user("short"), .assistant("also short")],
            settings: Compaction(),
            model: model
        )
        XCTAssertNil(outcome, "nothing to compact means no outcome at all")
        XCTAssertEqual(model.requests.count, 0, "no model call when nothing needs compacting")
    }
}

final class CompactedContextRenderingTests: XCTestCase {

    func testSchemaRequiresTheGoalAndDeadEnds() throws {
        let required = CompactedContext.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(required.contains("goal"))
        XCTAssertTrue(required.contains("deadEnds"))
        XCTAssertTrue(required.contains("decisions"))
    }

    func testRenderLeadsWithTheGoal() {
        let context = CompactedContext(goal: "Ship MCP OAuth for both transports")
        let rendered = ContextCompactor.render(context)
        XCTAssertTrue(rendered.contains("Goal: Ship MCP OAuth for both transports"))
    }

    func testRenderKeepsDeadEndsAndTheirReasons() {
        let context = CompactedContext(
            goal: "Fix discovery",
            deadEnds: [DeadEnd(
                approach: "Relative URL for the well-known path",
                failure: "URL(string:relativeTo:) dropped the issuer path"
            )]
        )
        let rendered = ContextCompactor.render(context)
        XCTAssertTrue(rendered.contains("Already tried and failed"))
        XCTAssertTrue(rendered.contains("dropped the issuer path"))
    }

    func testRenderOmitsEmptySections() {
        let rendered = ContextCompactor.render(CompactedContext(goal: "Just a goal"))
        XCTAssertFalse(rendered.contains("Open questions"))
        XCTAssertFalse(rendered.contains("Artifacts"))
    }

    func testRenderAttributesFactsAndArtifactsToTheirSource() {
        let context = CompactedContext(
            goal: "g",
            establishedFacts: [Fact(claim: "Notion returns 401 with a challenge", source: "curl")],
            artifacts: [Artifact(
                reference: "Sources/AI/MCP/MCPOAuth.swift",
                summary: "holds the discovery chain",
                producedBy: "read_file"
            )]
        )
        let rendered = ContextCompactor.render(context)
        XCTAssertTrue(rendered.contains("(via curl)"))
        XCTAssertTrue(rendered.contains("(via read_file)"))
    }

    func testContextRoundTripsThroughJSON() throws {
        let context = CompactedContext(
            goal: "g",
            constraints: ["no comments"],
            decisions: [Decision(what: "own the canvas", why: "edges must be flexible")],
            establishedFacts: [Fact(claim: "c", source: "s")],
            deadEnds: [DeadEnd(approach: "a", failure: "f")],
            openQuestions: ["q"],
            artifacts: [Artifact(reference: "r", summary: "s")]
        )
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(CompactedContext.self, from: data)
        XCTAssertEqual(decoded, context)
    }
}

final class ModelContextWindowTests: XCTestCase {

    func testKnownAnthropicModelsResolve() {
        XCTAssertEqual(ModelContextWindows.resolve(provider: "anthropic", modelID: "claude-opus-5"), 1_000_000)
        XCTAssertEqual(ModelContextWindows.resolve(provider: "anthropic", modelID: "claude-sonnet-5"), 1_000_000)
        XCTAssertEqual(
            ModelContextWindows.resolve(provider: "anthropic", modelID: "claude-haiku-4-5-20251001"),
            200_000
        )
    }

    func testDottedIDsNormalize() {
        XCTAssertEqual(
            ModelContextWindows.resolve(provider: "google", modelID: "gemini-2.5-pro"),
            1_000_000
        )
    }

    func testUnknownModelsFallBackConservatively() {
        let window = ModelContextWindows.resolve(provider: "acme", modelID: "totally-unknown-model")
        XCTAssertEqual(window, ModelContextWindows.conservativeDefault)
    }

    func testFallbackUnderestimatesRatherThanOverestimates() {
        XCTAssertLessThan(
            ModelContextWindows.conservativeDefault, 200_000,
            "an unknown model must compact early rather than risk overflowing the window"
        )
    }

    func testRegisteredOverrideWins() {
        ModelContextWindows.register(64_000, for: "my-local-build")
        XCTAssertEqual(ModelContextWindows.resolve(provider: "ollama", modelID: "my-local-build"), 64_000)
    }

    func testOverrideBeatsTheBuiltInTable() {
        ModelContextWindows.register(4_096, for: "claude-opus-5-tiny-shim")
        XCTAssertEqual(
            ModelContextWindows.resolve(provider: "anthropic", modelID: "claude-opus-5-tiny-shim"),
            4_096
        )
    }

    func testProtocolDefaultResolvesThroughTheCatalog() {
        XCTAssertEqual(MockLanguageModel(modelID: "claude-opus-5", parts: []).contextWindow, 1_000_000)
        XCTAssertEqual(
            MockLanguageModel(modelID: "who-knows", parts: []).contextWindow,
            ModelContextWindows.conservativeDefault
        )
    }

    func testRealProviderModelsCarryAWindow() {
        XCTAssertEqual(AnthropicModel("claude-opus-5", apiKey: "k").contextWindow, 1_000_000)
        XCTAssertEqual(XaiModel("grok-4", apiKey: "k").contextWindow, 256_000)
    }
}

final class CompactionIdempotentToolTests: XCTestCase {

    func testToolsAreNotIdempotentByDefault() {
        let tool = Tool(
            name: "send_email", description: "", parameters: .object(["type": "object"])
        ) { _ in .null }
        XCTAssertFalse(tool.isIdempotent)
    }

    func testIdempotentModifierMarksTheTool() {
        let tool = Tool(
            name: "read_file", description: "", parameters: .object(["type": "object"])
        ) { _ in .null }
        .idempotent()
        XCTAssertTrue(tool.isIdempotent)
    }
}

final class ToolDescriptionResolutionTests: XCTestCase {

    func testResolvingDescriptionKeepsEveryOtherToolTrait() {
        let tool = Tool(
            name: "search",
            description: "base",
            parameters: .object([:])
        ) { _ in .null }
            .idempotent()
            .loading(ToolLoading(deferLoading: true, cacheControl: .object(["type": .string("ephemeral")])))
            .describing { _ in "resolved" }

        let resolved = tool.resolvingDescription(tool.description(context: nil))

        XCTAssertEqual(resolved.description, "resolved")
        XCTAssertTrue(resolved.isIdempotent, "idempotence must survive description resolution")
        XCTAssertEqual(resolved.loading.deferLoading, true)
        XCTAssertNotNil(resolved.loading.cacheControl, "cache control must reach the provider")
        XCTAssertEqual(resolved.name, tool.name)
    }

    func testResolvedDescriptionIsStable() {
        let tool = Tool(name: "t", description: "base", parameters: .object([:])) { _ in .null }
            .describing { _ in "from-context" }
        let resolved = tool.resolvingDescription(tool.description(context: nil))
        XCTAssertEqual(
            resolved.description(context: .string("other")), "from-context",
            "once resolved the description should not re-derive"
        )
    }
}

final class CompactionPlanIntegrityTests: XCTestCase {

    func testEmptyMessagesAreNotSilentlyDropped() {
        let messages: [Message] = [
            .user("the goal"),
            Message(role: .assistant, content: []),
            .assistant("filler one"),
            .user("recent"),
            .assistant("recent reply")
        ]
        let plan = ContextCompactor.Plan(
            messages: messages,
            settings: Compaction(keepLastSteps: 2),
            idempotentTools: []
        )
        XCTAssertEqual(
            plan.pinned.count + plan.compressible.count + plan.workingSet.count,
            messages.count,
            "every message must be pinned, compressed, or in the working set"
        )
    }
}

final class TokenEstimateTests: XCTestCase {

    func testAttachmentsAreNotBilledByByteCount() {
        let photo = Message(role: .user, content: [
            .image(ImageContent(data: Data(repeating: 0, count: 1_000_000), mediaType: "image/jpeg"))
        ])
        let estimate = ContextCompactor.estimateTokens([photo])
        XCTAssertLessThan(
            estimate, 5_000,
            "an image must not score higher than an entire context window"
        )
    }
}

final class StepTimeoutTests: XCTestCase {

    /// A stream that keeps producing content must still hit the step limit,
    /// which is wall clock on the step rather than a stall timer.
    func testStepLimitFiresWhileContentIsStillArriving() async throws {
        let source = AsyncThrowingStream<StreamPart, Error> { continuation in
            Task {
                for index in 0..<400 {
                    continuation.yield(.textDelta("chunk \(index) "))
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.finish()
            }
        }

        let guarded = StreamTimeout.guarded(
            source, timeout: GenerationTimeout(step: .milliseconds(120))
        )

        do {
            for try await _ in guarded {}
            XCTFail("the step limit should have fired even though content kept arriving")
        } catch let error as AIError {
            guard case .timedOut(let scope, _, _) = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(scope, .step)
        }
    }
}

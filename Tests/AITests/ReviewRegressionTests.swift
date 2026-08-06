import XCTest
@testable import AI
import AITesting

final class ToolApprovalSignatureParityTests: XCTestCase {
    // Ground truth produced by the AI SDK's own algorithm (ai@7.0.37,
    // src/generate-text/tool-approval-signature.ts). A signature is minted on
    // one side of the wire and redeemed on the other, so these bytes have to
    // match exactly or cross-runtime approvals silently fail closed.
    private let input: JSONValue = [
        "path": "/tmp/x",
        "depth": .number(2),
        "force": .bool(true),
        "note": "a\"b\nc"
    ]

    func testCanonicalJSONMatchesJavaScript() {
        XCTAssertEqual(
            ToolApprovalSignature.canonicalJSON(input),
            #"{"depth":2,"force":true,"note":"a\"b\nc","path":"/tmp/x"}"#
        )
    }

    func testCanonicalNumbersMatchJSONStringify() {
        XCTAssertEqual(ToolApprovalSignature.canonicalNumber(2), "2")
        XCTAssertEqual(ToolApprovalSignature.canonicalNumber(-0.5), "-0.5")
        XCTAssertEqual(ToolApprovalSignature.canonicalNumber(1e-7), "1e-7")
        XCTAssertEqual(ToolApprovalSignature.canonicalNumber(1e21), "1e+21")
        XCTAssertEqual(ToolApprovalSignature.canonicalNumber(.infinity), "null")
    }

    func testInputDigestMatchesTheSDK() throws {
        try XCTSkipUnless(ToolApprovalSignature.isSupported)
        XCTAssertEqual(
            ToolApprovalSignature.inputDigest(input),
            "OW0GZbV6OSnfipzpiTKgU9rDqSuZH3ulEtF1S9a-VUk"
        )
    }

    func testPayloadOrderMatchesTheSDK() throws {
        try XCTSkipUnless(ToolApprovalSignature.isSupported)
        XCTAssertEqual(
            ToolApprovalSignature.payload(
                approvalID: "approval-c1", toolName: "deleteFile",
                toolCallID: "c1", input: input
            ),
            #"["ai-sdk-tool-approval-v1","approval-c1","c1","deleteFile","#
                + #""OW0GZbV6OSnfipzpiTKgU9rDqSuZH3ulEtF1S9a-VUk"]"#
        )
    }

    func testSignatureMatchesTheSDKByteForByte() throws {
        try XCTSkipUnless(ToolApprovalSignature.isSupported)
        let signature = ToolApprovalSignature.sign(
            secret: "s3cret", approvalID: "approval-c1",
            toolName: "deleteFile", toolCallID: "c1", input: input
        )
        XCTAssertEqual(signature, "vkZCEal4bzMkEHLqjk1ROBfDAQHCSGn6Zk53i0e5wJg")
        XCTAssertTrue(ToolApprovalSignature.verify(
            signature, secret: "s3cret", approvalID: "approval-c1",
            toolName: "deleteFile", toolCallID: "c1", input: input
        ))
    }

    func testTransposingToolNameAndCallIDBreaksVerification() throws {
        try XCTSkipUnless(ToolApprovalSignature.isSupported)
        XCTAssertFalse(ToolApprovalSignature.verify(
            "vkZCEal4bzMkEHLqjk1ROBfDAQHCSGn6Zk53i0e5wJg",
            secret: "s3cret", approvalID: "approval-c1",
            toolName: "c1", toolCallID: "deleteFile", input: input
        ))
    }
}

final class ResumedApprovalValidationTests: XCTestCase {
    private func history(
        arguments: JSONValue, approved: Bool = true
    ) -> [Message] {
        [
            .user("delete it"),
            Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "c1", name: "deleteFile", arguments: arguments))
            ]),
            Message(role: .user, content: [
                .toolApprovalResponse(ToolApprovalResponse(
                    approvalID: "approval-c1", toolCallID: "c1", approved: approved
                ))
            ])
        ]
    }

    private func deleteTool(_ ran: ExecutionFlag) -> Tool {
        Tool(
            name: "deleteFile",
            description: "Deletes.",
            parameters: [
                "type": "object",
                "properties": .object(["path": .object(["type": "string"])]),
                "required": .array(["path"])
            ]
        ) { _ in
            await ran.set()
            return .string("deleted")
        }
    }

    private func model() -> MockLanguageModel {
        MockLanguageModel(parts: [.textDelta("ok"), .finish(reason: .stop, usage: Usage())])
    }

    /// Without a shared secret the approval carries no proof of origin, so the
    /// policy is the only thing standing between client-supplied history and
    /// the tool. It has to run again on resume.
    func testPolicyIsReappliedToApprovalsFromHistory() async throws {
        let ran = ExecutionFlag()
        let consulted = ExecutionFlag()
        let result = try await generateText(
            model: model(),
            messages: history(arguments: ["path": "/tmp/x"]),
            tools: [deleteTool(ran)],
            toolApproval: ToolApprovalPolicy { _ in
                await consulted.set()
                return .denied(reason: "not allowed any more")
            }
        )

        let seen = await consulted.value
        XCTAssertTrue(seen, "the policy must be consulted on resume")
        let executed = await ran.value
        XCTAssertFalse(executed, "a policy denial must stop execution")
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertTrue(result.toolResults[0].denied)
        XCTAssertEqual(result.toolResults[0].output.stringValue, "not allowed any more")
    }

    func testApprovedCallStillRunsWhenThePolicyAgrees() async throws {
        let ran = ExecutionFlag()
        _ = try await generateText(
            model: model(),
            messages: history(arguments: ["path": "/tmp/x"]),
            tools: [deleteTool(ran)],
            toolApproval: ToolApprovalPolicy { _ in .approved() }
        )
        let executed = await ran.value
        XCTAssertTrue(executed)
    }

    /// The arguments come back through the client, so they can have been edited
    /// since the user saw them.
    func testTamperedArgumentsAreRejectedAgainstTheToolSchema() async throws {
        let ran = ExecutionFlag()
        do {
            _ = try await generateText(
                model: model(),
                messages: history(arguments: ["path": .number(42)]),
                tools: [deleteTool(ran)]
            )
            XCTFail("input that does not match the tool schema must abort the request")
        } catch {
            XCTAssertTrue("\(error)".contains("deleteFile"), "\(error)")
        }
        let executed = await ran.value
        XCTAssertFalse(executed)
    }
}

final class CompactionPairingTests: XCTestCase {
    private func transcript() -> [Message] {
        var messages: [Message] = [.system("be brief"), .user("start the job")]
        for index in 0..<6 {
            messages.append(Message(role: .assistant, content: [
                .toolCall(ToolCall(
                    id: "call-\(index)", name: "fetch", arguments: ["page": .number(Double(index))]
                ))
            ]))
            messages.append(Message(role: .tool, content: [
                .toolResult(ToolResult(
                    toolCallID: "call-\(index)",
                    name: "fetch",
                    // Long enough that the first result is what an `.errors`
                    // pin would otherwise strand.
                    output: .string(String(repeating: "x", count: 4_000)),
                    isError: index == 0
                ))
            ]))
        }
        return messages
    }

    private func orphans(_ messages: [Message]) -> (results: [String], calls: [String]) {
        var callIDs = Set<String>()
        var resultIDs = Set<String>()
        for message in messages {
            for part in message.content {
                switch part {
                case .toolCall(let call): callIDs.insert(call.id)
                case .toolResult(let result): resultIDs.insert(result.toolCallID)
                default: continue
                }
            }
        }
        return (
            results: resultIDs.subtracting(callIDs).sorted(),
            calls: callIDs.subtracting(resultIDs).sorted()
        )
    }

    func testGroupingKeepsCallsAndResultsTogether() {
        let groups = ContextCompactor.Plan.groups(transcript())
        XCTAssertEqual(groups.count, 8)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(groups[1].count, 1)
        for group in groups.dropFirst(2) {
            XCTAssertEqual(group.count, 2, "a call and its result form one group")
        }
    }

    /// The pinning rules and the keep-window split both used to cut between an
    /// assistant `tool_use` and the `tool_result` that answers it, which every
    /// provider rejects with a 400.
    func testPlanNeverStrandsAToolResult() {
        for keepLastSteps in 0...9 {
            let plan = ContextCompactor.Plan(
                messages: transcript(),
                settings: Compaction(keepLastSteps: keepLastSteps),
                idempotentTools: []
            )
            let rebuilt = plan.pinned
                + [Message(role: .user, content: [.text("[compacted context]")])]
                + plan.workingSet
            let (results, _) = orphans(rebuilt)
            XCTAssertTrue(
                results.isEmpty,
                "keepLastSteps \(keepLastSteps) stranded tool results \(results)"
            )
        }
    }

    func testErrorPinningPullsInTheCallThatFailed() {
        let plan = ContextCompactor.Plan(
            messages: transcript(),
            settings: Compaction(pinning: .errors, keepLastSteps: 2),
            idempotentTools: []
        )
        let pinnedCallIDs = plan.pinned.flatMap { message in
            message.content.compactMap { part -> String? in
                if case .toolCall(let call) = part { return call.id }
                return nil
            }
        }
        XCTAssertTrue(
            pinnedCallIDs.contains("call-0"),
            "pinning the failed result must pin the call that produced it"
        )
    }
}

final class PruneMessagesKeepWindowTests: XCTestCase {
    func testACallIsKeptWhenItsResultIsInTheKeepWindow() {
        let messages: [Message] = [
            Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "c1", name: "search", arguments: .object([:])))
            ]),
            Message(role: .tool, content: [
                .toolResult(ToolResult(toolCallID: "c1", name: "search", output: .string("hit")))
            ])
        ]

        let pruned = pruneMessages(messages, toolCalls: .beforeLastMessage)
        XCTAssertEqual(pruned.count, 2, "the pair referenced by the keep window survives")

        let callIDs = pruned.flatMap { message in
            message.content.compactMap { part -> String? in
                if case .toolCall(let call) = part { return call.id }
                return nil
            }
        }
        XCTAssertEqual(callIDs, ["c1"])
    }

    func testCallsOutsideTheKeepWindowStillGo() {
        let messages: [Message] = [
            Message(role: .assistant, content: [
                .toolCall(ToolCall(id: "old", name: "search", arguments: .object([:])))
            ]),
            Message(role: .tool, content: [
                .toolResult(ToolResult(toolCallID: "old", name: "search", output: .string("hit")))
            ]),
            .user("and now something else")
        ]

        let pruned = pruneMessages(messages, toolCalls: .beforeLastMessage)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned[0].text, "and now something else")
    }
}

final class ImageMediaTypeTests: XCTestCase {
    func testMediaTypeIsSniffedWhenTheProviderDoesNotReportIt() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 16))
        let result = try await generateImage(
            model: StubImageModel(response: ImageModelResponse(images: [jpeg])),
            prompt: "a cat"
        )
        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertEqual(result.file.mediaType, "image/jpeg")
        XCTAssertEqual(result.files.first?.mediaType, "image/jpeg")
    }

    func testAReportedMediaTypeWins() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 16))
        let result = try await generateImage(
            model: StubImageModel(
                response: ImageModelResponse(images: [bytes], mediaType: "image/webp")
            ),
            prompt: "a cat"
        )
        XCTAssertEqual(result.mediaType, "image/webp")
    }

    private struct StubImageModel: ImageModel {
        let provider = "stub"
        let modelID = "stub"
        let response: ImageModelResponse

        func generateImages(_ request: ImageModelRequest) async throws -> ImageModelResponse {
            response
        }
    }
}

final class MissingToolResultsTests: XCTestCase {
    private func call(_ id: String, providerExecuted: Bool = false) -> Message {
        Message(role: .assistant, content: [
            .toolCall(ToolCall(
                id: id, name: "fetch", arguments: .object([:]),
                providerExecuted: providerExecuted
            ))
        ])
    }

    private func result(_ id: String) -> Message {
        Message(role: .tool, content: [
            .toolResult(ToolResult(toolCallID: id, name: "fetch", output: .string("ok")))
        ])
    }

    func testAnsweredCallsPass() throws {
        try StepRequest.validateToolResults(in: [
            .user("go"), call("c1"), result("c1"), .user("again")
        ])
    }

    /// The tail of a paused run: the client still owes a result, and the next
    /// call will supply it.
    func testATrailingUnansweredCallIsNotAnError() throws {
        try StepRequest.validateToolResults(in: [.user("go"), call("c1")])
    }

    func testAUserTurnPastAnUnansweredCallIsRejected() {
        XCTAssertThrowsError(
            try StepRequest.validateToolResults(in: [.user("go"), call("c1"), .user("never mind")])
        ) { error in
            guard case AIError.missingToolResults(let ids) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(ids, ["c1"])
        }
    }

    func testProviderExecutedCallsNeedNoResult() throws {
        try StepRequest.validateToolResults(in: [
            .user("go"), call("c1", providerExecuted: true), .user("thanks")
        ])
    }

    func testACallAwaitingAnApprovalDecisionIsNotMissing() throws {
        try StepRequest.validateToolResults(in: [
            .user("go"),
            call("c1"),
            Message(role: .user, content: [
                .toolApprovalResponse(ToolApprovalResponse(
                    approvalID: "approval-c1", toolCallID: "c1", approved: true
                ))
            ])
        ])
    }
}

final class ToolCallRepairTests: XCTestCase {
    private let schema: JSONValue = [
        "type": "object",
        "properties": .object(["path": .object(["type": "string"])]),
        "required": .array(["path"])
    ]

    private func model(_ call: ToolCall) -> MockLanguageModel {
        MockLanguageModel(parts: [.toolCall(call), .finish(reason: .toolCalls, usage: Usage())])
    }

    func testRepairThrowingIsReportedAsRepairFailure() async throws {
        let tool = Tool(name: "read", description: "Reads.", parameters: schema) { _ in
            .string("contents")
        }
        struct Boom: Error {}

        let result = try await generateText(
            model: model(ToolCall(id: "c1", name: "raed", arguments: ["path": "/tmp/x"])),
            messages: [.user("read it")],
            tools: [tool],
            maxSteps: 1,
            repairToolCall: { _, _ in throw Boom() }
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertTrue(result.toolResults[0].isError)
        XCTAssertTrue(
            result.toolResults[0].output.stringValue?.contains("Could not repair") == true,
            "\(result.toolResults[0].output)"
        )
    }

    func testRepairIsOfferedInputThatDoesNotMatchTheSchema() async throws {
        let tool = Tool(name: "read", description: "Reads.", parameters: schema) { arguments in
            .string("read \(arguments["path"]?.stringValue ?? "")")
        }

        let result = try await generateText(
            model: model(ToolCall(id: "c1", name: "read", arguments: ["path": .number(42)])),
            messages: [.user("read it")],
            tools: [tool],
            maxSteps: 1,
            repairToolCall: { call, _ in
                ToolCall(id: call.id, name: call.name, arguments: ["path": "/tmp/x"])
            }
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertFalse(result.toolResults[0].isError, "\(result.toolResults[0].output)")
        XCTAssertEqual(result.toolResults[0].output.stringValue, "read /tmp/x")
    }

    func testUnrepairableInputBecomesAToolErrorRatherThanKillingTheRun() async throws {
        let tool = Tool(name: "read", description: "Reads.", parameters: schema) { _ in
            XCTFail("the tool must not run on input that fails its schema")
            return .null
        }

        let result = try await generateText(
            model: model(ToolCall(id: "c1", name: "read", arguments: .object([:]))),
            messages: [.user("read it")],
            tools: [tool],
            maxSteps: 1
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertTrue(result.toolResults[0].isError)
        XCTAssertTrue(
            result.toolResults[0].output.stringValue?.contains("Invalid input") == true,
            "\(result.toolResults[0].output)"
        )
    }

    func testWellFormedCallsAreUntouched() async throws {
        let tool = Tool(name: "read", description: "Reads.", parameters: schema) { arguments in
            .string("read \(arguments["path"]?.stringValue ?? "")")
        }

        let result = try await generateText(
            model: model(ToolCall(id: "c1", name: "read", arguments: ["path": "/tmp/x"])),
            messages: [.user("read it")],
            tools: [tool],
            maxSteps: 1
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertFalse(result.toolResults[0].isError)
        XCTAssertEqual(result.toolResults[0].output.stringValue, "read /tmp/x")
    }

    /// Tools that declare no properties accept anything, so nothing that used
    /// to run should start failing validation.
    func testAnOpenSchemaAcceptsAnyArguments() async throws {
        let tool = Tool(
            name: "anything", description: "Anything.", parameters: ["type": "object"]
        ) { _ in .string("ok") }

        let result = try await generateText(
            model: model(ToolCall(id: "c1", name: "anything", arguments: ["x": .number(1)])),
            messages: [.user("go")],
            tools: [tool],
            maxSteps: 1
        )

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertFalse(result.toolResults[0].isError, "\(result.toolResults[0].output)")
    }
}

final class TranscriptionMediaTypeTests: XCTestCase {
    func testAnExplicitContainerTypeIsNotOverwritten() {
        // Every ISO-BMFF file carries `ftyp`, so sniffing cannot tell a
        // QuickTime movie from an audio-only MP4.
        let movie = Data([0, 0, 0, 0x20] + Array("ftypqt  ".utf8) + [0, 0, 0, 0])
        XCTAssertEqual(detectAudioMediaType(movie), "audio/mp4")
    }
}

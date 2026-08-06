import Foundation

public struct Decision: Codable, Sendable, Hashable {
    public var what: String
    public var why: String

    public init(what: String, why: String) {
        self.what = what
        self.why = why
    }
}

public struct Fact: Codable, Sendable, Hashable {
    public var claim: String
    public var source: String?

    public init(claim: String, source: String? = nil) {
        self.claim = claim
        self.source = source
    }
}

public struct DeadEnd: Codable, Sendable, Hashable {
    public var approach: String
    public var failure: String

    public init(approach: String, failure: String) {
        self.approach = approach
        self.failure = failure
    }
}

public struct Artifact: Codable, Sendable, Hashable {
    public var reference: String
    public var summary: String
    public var producedBy: String?

    public init(reference: String, summary: String, producedBy: String? = nil) {
        self.reference = reference
        self.summary = summary
        self.producedBy = producedBy
    }
}

public struct CompactedContext: Codable, Sendable, Hashable {
    public var goal: String
    public var constraints: [String]
    public var decisions: [Decision]
    public var establishedFacts: [Fact]
    public var deadEnds: [DeadEnd]
    public var openQuestions: [String]
    public var artifacts: [Artifact]

    public init(
        goal: String,
        constraints: [String] = [],
        decisions: [Decision] = [],
        establishedFacts: [Fact] = [],
        deadEnds: [DeadEnd] = [],
        openQuestions: [String] = [],
        artifacts: [Artifact] = []
    ) {
        self.goal = goal
        self.constraints = constraints
        self.decisions = decisions
        self.establishedFacts = establishedFacts
        self.deadEnds = deadEnds
        self.openQuestions = openQuestions
        self.artifacts = artifacts
    }

    public var isEmpty: Bool {
        goal.isEmpty && constraints.isEmpty && decisions.isEmpty
            && establishedFacts.isEmpty && deadEnds.isEmpty
            && openQuestions.isEmpty && artifacts.isEmpty
    }

    static let schema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "goal": .object([
                "type": "string",
                "description": .string(
                    "The original task, restated in one or two sentences. "
                    + "This must never be omitted or generalized away."
                )
            ]),
            "constraints": .object([
                "type": "array",
                "description": "Requirements or prohibitions the user stated.",
                "items": .object(["type": "string"])
            ]),
            "decisions": .object([
                "type": "array",
                "description": "Choices already made, each with the reason it was made.",
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "what": .object(["type": "string"]),
                        "why": .object(["type": "string"])
                    ]),
                    "required": .array([.string("what"), .string("why")]),
                    "additionalProperties": .bool(false)
                ])
            ]),
            "establishedFacts": .object([
                "type": "array",
                "description": "Concrete findings discovered so far, with the tool that found them.",
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "claim": .object(["type": "string"]),
                        "source": .object(["type": "string"])
                    ]),
                    "required": .array([.string("claim")]),
                    "additionalProperties": .bool(false)
                ])
            ]),
            "deadEnds": .object([
                "type": "array",
                "description": .string(
                    "Approaches already tried that did not work, and why. "
                    + "Preserve these so the work is not repeated."
                ),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "approach": .object(["type": "string"]),
                        "failure": .object(["type": "string"])
                    ]),
                    "required": .array([.string("approach"), .string("failure")]),
                    "additionalProperties": .bool(false)
                ])
            ]),
            "openQuestions": .object([
                "type": "array",
                "description": "Unresolved questions that still block the task.",
                "items": .object(["type": "string"])
            ]),
            "artifacts": .object([
                "type": "array",
                "description": .string(
                    "Files, records, or resources touched. Reference them by path or id "
                    + "with a one-line description — never inline their contents."
                ),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "reference": .object(["type": "string"]),
                        "summary": .object(["type": "string"]),
                        "producedBy": .object(["type": "string"])
                    ]),
                    "required": .array([.string("reference"), .string("summary")]),
                    "additionalProperties": .bool(false)
                ])
            ])
        ]),
        "required": .array([
            .string("goal"), .string("constraints"), .string("decisions"),
            .string("establishedFacts"), .string("deadEnds"),
            .string("openQuestions"), .string("artifacts")
        ]),
        "additionalProperties": .bool(false)
    ])
}

public struct CompactionBudget: Sendable, Hashable {
    public var contextWindow: Int?
    public var workingSet: Double
    public var compacted: Double

    public init(contextWindow: Int? = nil, workingSet: Double = 0.5, compacted: Double = 0.2) {
        self.contextWindow = contextWindow
        self.workingSet = workingSet
        self.compacted = compacted
    }

    public func contextWindow(for model: any LanguageModel) -> Int {
        contextWindow ?? model.contextWindow
    }

    public func workingSetTokens(window: Int) -> Int {
        Int(Double(window) * workingSet)
    }

    public func compactedTokens(window: Int) -> Int {
        Int(Double(window) * compacted)
    }

    public func workingSetTokens(for model: any LanguageModel) -> Int {
        workingSetTokens(window: contextWindow(for: model))
    }

    public func compactedTokens(for model: any LanguageModel) -> Int {
        compactedTokens(window: contextWindow(for: model))
    }
}

public struct CompactionPinning: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let firstUserMessage = CompactionPinning(rawValue: 1 << 0)
    public static let errors = CompactionPinning(rawValue: 1 << 1)
    public static let liveReferences = CompactionPinning(rawValue: 1 << 2)

    public static let `default`: CompactionPinning = [.firstUserMessage, .errors, .liveReferences]
}

public struct CompactionEvent: Sendable {
    public var messagesBefore: Int
    public var messagesAfter: Int
    public var estimatedTokensBefore: Int
    public var estimatedTokensAfter: Int
    public var context: CompactedContext
    public var pointerizedTools: [String]
}

public struct Compaction: Sendable {
    public var budget: CompactionBudget
    public var pinning: CompactionPinning
    public var keepLastSteps: Int
    public var onCompact: (@Sendable (CompactionEvent) -> Void)?

    public init(
        budget: CompactionBudget = CompactionBudget(),
        pinning: CompactionPinning = .default,
        keepLastSteps: Int = 4,
        onCompact: (@Sendable (CompactionEvent) -> Void)? = nil
    ) {
        self.budget = budget
        self.pinning = pinning
        self.keepLastSteps = keepLastSteps
        self.onCompact = onCompact
    }
}

public enum ContextCompactor {

    public static func estimateTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    /// Providers bill an attachment at a roughly fixed cost that has nothing to
    /// do with its byte size, so counting bytes as characters would score a
    /// single photo higher than an entire context window and compact from the
    /// first step of any multimodal run.
    static let attachmentTokens = 1_500

    static func estimateTokens(_ message: Message) -> Int {
        var characters = 0
        var attachments = 0
        for part in message.content {
            switch part {
            case .text(let text):
                characters += text.count
            case .toolCall(let call):
                characters += call.name.count + Reference.encodedLength(call.arguments)
            case .toolResult(let result):
                characters += result.name.count + Reference.encodedLength(result.output)
            case .image(let image):
                if image.data != nil {
                    attachments += 1
                } else {
                    characters += image.url?.absoluteString.count ?? 0
                }
            case .file(let file):
                if file.data != nil {
                    attachments += 1
                } else {
                    characters += file.url?.absoluteString.count ?? 0
                }
            case .toolApprovalResponse:
                characters += 32
            }
        }
        return max(1, characters / 4 + attachments * attachmentTokens)
    }

    static func shouldCompact(_ messages: [Message], budget: CompactionBudget, window: Int) -> Bool {
        estimateTokens(messages) > budget.workingSetTokens(window: window)
    }

    /// The result of a compaction that actually ran. `compact` returns nil when
    /// nothing happened, so there is never a set of messages the caller has to
    /// know to ignore.
    public struct CompactionOutcome: Sendable {
        public var messages: [Message]
        public var event: CompactionEvent
    }

    public static func compact(
        _ messages: [Message],
        settings: Compaction,
        model: any LanguageModel,
        tools: [any AIToolProtocol] = [],
        existing: CompactedContext? = nil
    ) async throws -> CompactionOutcome? {
        let window = settings.budget.contextWindow(for: model)
        guard shouldCompact(messages, budget: settings.budget, window: window) else {
            return nil
        }

        let plan = Plan(
            messages: messages,
            settings: settings,
            idempotentTools: Set(tools.filter(\.isIdempotent).map(\.name))
        )
        guard !plan.compressible.isEmpty else { return nil }

        let tokensBefore = estimateTokens(messages)
        let extracted = try await extract(
            plan.compressible,
            existing: existing,
            model: model,
            compactedTokens: settings.budget.compactedTokens(window: window)
        )

        var rebuilt: [Message] = []
        rebuilt.append(contentsOf: plan.pinned)
        rebuilt.append(Message(role: .user, content: [.text(render(extracted))]))
        rebuilt.append(contentsOf: plan.workingSet)

        let event = CompactionEvent(
            messagesBefore: messages.count,
            messagesAfter: rebuilt.count,
            estimatedTokensBefore: tokensBefore,
            estimatedTokensAfter: estimateTokens(rebuilt),
            context: extracted,
            pointerizedTools: plan.pointerizedTools.sorted()
        )
        settings.onCompact?(event)
        return CompactionOutcome(messages: rebuilt, event: event)
    }

    struct Plan {
        var pinned: [Message] = []
        var compressible: [Message] = []
        var workingSet: [Message] = []
        var pointerizedTools: Set<String> = []

        init(messages: [Message], settings: Compaction, idempotentTools: Set<String>) {
            // A tool call and the results that answer it are one unit as far as
            // every provider is concerned: a `tool_result` with no matching
            // `tool_use` in the same request is a 400, not a degraded prompt.
            // So the split and the pin decision both happen per group, never
            // per message.
            let groups = Self.groups(messages)

            var headGroups = groups
            var kept: [Message] = []
            while kept.count < settings.keepLastSteps, let last = headGroups.last {
                kept.insert(contentsOf: last, at: 0)
                headGroups.removeLast()
            }
            workingSet = kept

            let live = settings.pinning.contains(.liveReferences)
                ? liveIdentifiers(in: workingSet)
                : []

            // The first user message is the goal, so it is pinned once and the
            // rest of the user turns are free to compress.
            var wantsFirstUser = settings.pinning.contains(.firstUserMessage)

            for group in headGroups {
                var pin = false
                for message in group {
                    // Every message is asked, even once the group is decided,
                    // so `wantsFirstUser` is consumed by the message that
                    // actually is the first user turn.
                    if shouldPin(
                        message, settings: settings, live: live, wantsFirstUser: &wantsFirstUser
                    ) {
                        pin = true
                    }
                }
                guard !pin else {
                    pinned.append(contentsOf: group)
                    continue
                }
                for message in group {
                    compressible.append(pointerizing(message, idempotentTools: idempotentTools))
                }
            }
        }

        /// Splits the transcript into runs that have to survive or vanish
        /// together: an assistant message that opens tool calls stays joined to
        /// the messages that approve and answer them.
        static func groups(_ messages: [Message]) -> [[Message]] {
            var groups: [[Message]] = []
            var current: [Message] = []
            var open: Set<String> = []

            func flush() {
                if !current.isEmpty { groups.append(current) }
                current = []
                open = []
            }

            for message in messages {
                var opened: Set<String> = []
                var settled: Set<String> = []
                var referenced: Set<String> = []
                for part in message.content {
                    switch part {
                    case .toolCall(let call):
                        opened.insert(call.id)
                    case .toolResult(let result):
                        settled.insert(result.toolCallID)
                        referenced.insert(result.toolCallID)
                    case .toolApprovalResponse(let response):
                        // An approval joins the group but does not close the
                        // call — the result still has to land alongside it.
                        referenced.insert(response.toolCallID)
                    default:
                        continue
                    }
                }

                if open.isEmpty || referenced.isDisjoint(with: open) { flush() }
                current.append(message)
                open.subtract(settled)
                open.formUnion(opened)
                if open.isEmpty { flush() }
            }

            flush()
            return groups
        }

        private func shouldPin(
            _ message: Message,
            settings: Compaction,
            live: Set<String>,
            wantsFirstUser: inout Bool
        ) -> Bool {
            if message.role == .system { return true }
            if wantsFirstUser, message.role == .user {
                wantsFirstUser = false
                return true
            }
            if settings.pinning.contains(.errors), carriesError(message) { return true }
            if !live.isEmpty, references(message, live) { return true }
            return false
        }

        /// Replaces re-fetchable tool output with a pointer to it, recording
        /// which tools were shortened.
        private mutating func pointerizing(
            _ message: Message, idempotentTools: Set<String>
        ) -> Message {
            var trimmed = message
            trimmed.content = message.content.map { part in
                guard case .toolResult(let result) = part,
                      idempotentTools.contains(result.name) else { return part }
                pointerizedTools.insert(result.name)
                return .toolResult(ToolResult(
                    toolCallID: result.toolCallID,
                    name: result.name,
                    output: .string(pointer(for: result))
                ))
            }
            return trimmed
        }
    }

    static func pointer(for result: ToolResult) -> String {
        let size = Reference.encodedLength(result.output)
        return "[omitted: \(result.name) returned ~\(size) bytes — re-run the tool to retrieve it]"
    }

    static func carriesError(_ message: Message) -> Bool {
        for part in message.content {
            if case .toolResult(let result) = part, result.isError { return true }
        }
        return false
    }

    static func liveIdentifiers(in messages: [Message]) -> Set<String> {
        var found: Set<String> = []
        for message in messages {
            for part in message.content {
                let text: String
                switch part {
                case .text(let value): text = value
                case .toolCall(let call): text = Reference.encoded(call.arguments)
                case .toolResult(let result): text = Reference.encoded(result.output)
                default: continue
                }
                found.formUnion(identifiers(in: text))
            }
        }
        return found
    }

    static func identifiers(in text: String) -> Set<String> {
        var results: Set<String> = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 4 else { return }
            let interesting = current.contains("/") || current.contains(".")
                || current.contains("_") || current.contains("-")
            guard interesting else { return }
            results.insert(current)
        }
        for character in text {
            if character.isLetter || character.isNumber
                || character == "/" || character == "." || character == "_" || character == "-" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return results
    }

    static func references(_ message: Message, _ live: Set<String>) -> Bool {
        for part in message.content {
            let text: String
            switch part {
            case .text(let value): text = value
            case .toolCall(let call): text = Reference.encoded(call.arguments)
            case .toolResult(let result): text = Reference.encoded(result.output)
            default: continue
            }
            if !identifiers(in: text).isDisjoint(with: live) { return true }
        }
        return false
    }

    static func extract(
        _ messages: [Message],
        existing: CompactedContext?,
        model: any LanguageModel,
        compactedTokens: Int
    ) async throws -> CompactedContext {
        var transcript = ""
        if let existing, !existing.isEmpty {
            transcript += "Previously compacted context:\n\(render(existing))\n\n"
        }
        transcript += "Transcript to compact:\n\(describe(messages))"

        let system = """
        You compact an agent transcript so the run can continue without losing what matters.

        Preserve, verbatim in meaning: the original goal, the user's constraints, every \
        decision and the reason behind it, and every approach that was tried and failed. \
        Dead ends are as valuable as successes — without them the agent repeats the failure.

        Compress hard: bulk tool output. Reference files and records by path or id with a \
        one-line description instead of reproducing their contents.

        Do not invent anything. If a field has nothing to record, return an empty list for it.
        """

        let result = try await generateObject(
            model: model,
            of: CompactedContext.self,
            schema: CompactedContext.schema,
            schemaName: "compacted_context",
            schemaDescription: "The load-bearing state of an agent run, after compaction.",
            system: system,
            prompt: transcript,
            maxOutputTokens: max(1024, compactedTokens / 4)
        )
        return result.object
    }

    static func describe(_ messages: [Message]) -> String {
        messages.map { message in
            let body = message.content.map { part -> String in
                switch part {
                case .text(let text): return text
                case .toolCall(let call):
                    return "called \(call.name)(\(Reference.encoded(call.arguments)))"
                case .toolResult(let result):
                    let tag = result.isError ? "FAILED" : "returned"
                    return "\(result.name) \(tag): \(Reference.encoded(result.output))"
                case .image: return "[image]"
                case .file: return "[file]"
                case .toolApprovalResponse(let response):
                    return "approval for \(response.toolCallID): \(response.approved)"
                }
            }
            .joined(separator: "\n")
            return "\(message.role.rawValue):\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    public static func render(_ context: CompactedContext) -> String {
        var lines: [String] = ["[compacted context]", "", "Goal: \(context.goal)"]

        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("")
            lines.append("\(title):")
            lines.append(contentsOf: items.map { "- \($0)" })
        }

        section("Constraints", context.constraints)
        section("Decisions", context.decisions.map { "\($0.what) — \($0.why)" })
        section("Established", context.establishedFacts.map { fact in
            guard let source = fact.source, !source.isEmpty else { return fact.claim }
            return "\(fact.claim) (via \(source))"
        })
        section("Already tried and failed", context.deadEnds.map { "\($0.approach) — \($0.failure)" })
        section("Open questions", context.openQuestions)
        section("Artifacts", context.artifacts.map { artifact in
            guard let by = artifact.producedBy, !by.isEmpty else {
                return "\(artifact.reference): \(artifact.summary)"
            }
            return "\(artifact.reference): \(artifact.summary) (via \(by))"
        })

        return lines.joined(separator: "\n")
    }
}

extension ContextCompactor {
    enum Reference {
        // Built once. `estimateTokens` walks the whole transcript on every step
        // of the loop, so a fresh encoder per value showed up as real work.
        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return encoder
        }()

        static func encoded(_ value: JSONValue) -> String {
            if case .string(let text) = value { return text }
            guard let data = try? encoder.encode(value),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }

        static func encodedLength(_ value: JSONValue) -> Int {
            if case .string(let text) = value { return text.count }
            // Only the size is wanted, so skip materialising the String.
            return (try? encoder.encode(value).count) ?? 0
        }
    }
}

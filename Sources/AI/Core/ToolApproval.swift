import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ToolApprovalDecision: Sendable, Hashable {
    case notApplicable
    case approved(reason: String? = nil)
    case denied(reason: String? = nil)
    case userApproval(reason: String? = nil)

    public var reason: String? {
        switch self {
        case .notApplicable: nil
        case .approved(let reason), .denied(let reason), .userApproval(let reason): reason
        }
    }
}

public struct ToolApprovalContext: Sendable {
    public var toolCall: ToolCall
    public var tool: (any AIToolProtocol)?
    public var messages: [Message]
    public var stepNumber: Int
    public var steps: [StepResult]

    public init(
        toolCall: ToolCall,
        tool: (any AIToolProtocol)? = nil,
        messages: [Message] = [],
        stepNumber: Int = 0,
        steps: [StepResult] = []
    ) {
        self.toolCall = toolCall
        self.tool = tool
        self.messages = messages
        self.stepNumber = stepNumber
        self.steps = steps
    }
}

public struct ToolApprovalPolicy: Sendable, ExpressibleByDictionaryLiteral {
    private let decider: @Sendable (ToolApprovalContext) async -> ToolApprovalDecision

    public init(
        _ decide: @escaping @Sendable (ToolApprovalContext) async -> ToolApprovalDecision
    ) {
        self.decider = decide
    }

    public init(dictionaryLiteral elements: (String, ToolApprovalDecision)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    public init(_ decisions: [String: ToolApprovalDecision]) {
        self.decider = { context in decisions[context.toolCall.name] ?? .notApplicable }
    }

    public static func tools(_ decisions: [String: ToolApprovalDecision]) -> ToolApprovalPolicy {
        ToolApprovalPolicy(decisions)
    }

    public static func perTool(
        _ deciders: [String: @Sendable (ToolApprovalContext) async -> ToolApprovalDecision]
    ) -> ToolApprovalPolicy {
        ToolApprovalPolicy { context in
            guard let decide = deciders[context.toolCall.name] else { return .notApplicable }
            return await decide(context)
        }
    }

    public func decide(_ context: ToolApprovalContext) async -> ToolApprovalDecision {
        await decider(context)
    }
}

public enum ToolApprovalSignature {
    // Matches the AI SDK's domain string, field order, and encoding exactly.
    // A signature is minted on one side of the wire and redeemed on the other,
    // so anything that differs here silently rejects every approval that
    // crosses between runtimes.
    static let domain = "ai-sdk-tool-approval-v1"

    /// Whether this platform can sign approvals at all. Without it every
    /// signature check would fail, and the caller deserves to hear that once at
    /// configuration time rather than as a denial on every tool call.
    public static var isSupported: Bool {
        #if canImport(CryptoKit)
        return true
        #else
        return false
        #endif
    }

    public static func sign(
        secret: String, approvalID: String, toolName: String, toolCallID: String, input: JSONValue
    ) -> String? {
        #if canImport(CryptoKit)
        guard !secret.isEmpty else { return nil }
        let payload = self.payload(
            approvalID: approvalID, toolName: toolName, toolCallID: toolCallID, input: input
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8))
        )
        return base64URL(Data(code))
        #else
        return nil
        #endif
    }

    public static func verify(
        _ signature: String?,
        secret: String,
        approvalID: String,
        toolName: String,
        toolCallID: String,
        input: JSONValue
    ) -> Bool {
        guard let signature, !signature.isEmpty else { return false }
        guard let expected = sign(
            secret: secret, approvalID: approvalID,
            toolName: toolName, toolCallID: toolCallID, input: input
        ) else { return false }
        return constantTimeEquals(signature, expected)
    }

    static func payload(
        approvalID: String, toolName: String, toolCallID: String, input: JSONValue
    ) -> String {
        canonicalJSON(.array([
            .string(domain),
            .string(approvalID),
            .string(toolCallID),
            .string(toolName),
            .string(inputDigest(input))
        ]))
    }

    /// The input is signed as a digest rather than inline, so the HMAC payload
    /// stays a fixed size no matter how large a tool's arguments are.
    static func inputDigest(_ input: JSONValue) -> String {
        #if canImport(CryptoKit)
        return base64URL(Data(SHA256.hash(data: Data(canonicalJSON(input).utf8))))
        #else
        return ""
        #endif
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `JSON.stringify` with object keys sorted: the same value has to produce
    /// the same bytes in both runtimes or the digests will not line up.
    static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return canonicalNumber(number)
        case .string(let text):
            return canonicalString(text)
        case .array(let items):
            return "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let object):
            let entries = object.keys.sorted().map { key in
                "\(canonicalString(key)):\(canonicalJSON(object[key] ?? .null))"
            }
            return "{" + entries.joined(separator: ",") + "}"
        }
    }

    static func canonicalNumber(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number.rounded() == number, abs(number) < 1e21,
           let integer = Int64(exactly: number.rounded()) {
            return String(integer)
        }
        var text = String(number)
        if text.hasSuffix(".0") { text.removeLast(2) }
        guard let exponentIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return text
        }
        // Swift writes `1e-07`, JavaScript writes `1e-7`.
        let mantissa = String(text[..<exponentIndex])
        var exponent = String(text[text.index(after: exponentIndex)...])
        var sign = ""
        if exponent.hasPrefix("-") || exponent.hasPrefix("+") {
            sign = String(exponent.removeFirst())
        }
        while exponent.count > 1, exponent.hasPrefix("0") { exponent.removeFirst() }
        return mantissa + "e" + sign + exponent
    }

    static func canonicalString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

import Foundation

public enum AIError: Error, Sendable, CustomStringConvertible {
    case http(status: Int, body: String)
    case decoding(String)
    case unknownTool(String)
    case invalidRequest(String)
    case transport(String)
    case noObjectGenerated(String)
    case timedOut(scope: TimeoutScope, limit: Duration, tool: String?)
    case invalidToolInput(tool: String, reason: String)
    case invalidToolContext(tool: String, reason: String)
    case missingToolResults([String])
    case toolCallRepairFailed(tool: String, reason: String)
    case invalidToolApproval(String)
    case unsupportedFunctionality(String)
    case authorizationRequired(url: URL)

    public var description: String {
        switch self {
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .decoding(let m): "Decoding error: \(m)"
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidRequest(let m): "Invalid request: \(m)"
        case .transport(let m): "Transport error: \(m)"
        case .noObjectGenerated(let m): "No object generated: \(m)"
        case .timedOut(let scope, let limit, let tool):
            if let tool {
                "Timed out: tool '\(tool)' exceeded \(limit)"
            } else {
                "Timed out: \(scope.rawValue) exceeded \(limit)"
            }
        case .invalidToolInput(let tool, let reason):
            "Invalid input for tool '\(tool)': \(reason)"
        case .invalidToolContext(let tool, let reason):
            "Invalid context for tool '\(tool)': \(reason)"
        case .missingToolResults(let ids):
            "Missing tool results for: \(ids.joined(separator: ", "))"
        case .toolCallRepairFailed(let tool, let reason):
            "Could not repair the call to '\(tool)': \(reason)"
        case .invalidToolApproval(let m):
            "Invalid tool approval: \(m)"
        case .unsupportedFunctionality(let m):
            "Unsupported functionality: \(m)"
        case .authorizationRequired(let url):
            "Authorization required: open \(url.absoluteString) to sign in, then pass the "
                + "redirect back to complete(callbackURL:)"
        }
    }
}

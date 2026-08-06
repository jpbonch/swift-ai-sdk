import Foundation

public enum ModelContextWindows {

    public static let conservativeDefault = 128_000

    private static let overrides = OverrideStore()

    public static func register(_ contextWindow: Int, for modelID: String) {
        overrides.set(contextWindow, for: normalize(modelID))
    }

    public static func resolve(provider: String, modelID: String) -> Int {
        let id = normalize(modelID)
        if let override = overrides.value(for: id) { return override }
        if let known = table.first(where: { id.contains($0.pattern) })?.window { return known }
        return conservativeDefault
    }

    static func normalize(_ modelID: String) -> String {
        modelID.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    private static let table: [(pattern: String, window: Int)] = [
        ("claude-fable-5", 1_000_000),
        ("claude-mythos-5", 1_000_000),
        ("claude-mythos-preview", 1_000_000),
        ("claude-opus-5", 1_000_000),
        ("claude-opus-4-8", 1_000_000),
        ("claude-opus-4-7", 1_000_000),
        ("claude-opus-4-6", 1_000_000),
        ("claude-sonnet-5", 1_000_000),
        ("claude-sonnet-4-6", 1_000_000),
        ("claude-haiku-4-5", 200_000),
        ("claude-opus-4-5", 200_000),
        ("claude-opus-4-1", 200_000),
        ("claude-opus-4", 200_000),
        ("claude-sonnet-4-5", 200_000),
        ("claude-sonnet-4", 200_000),
        ("claude-3", 200_000),

        ("gemini-3", 1_000_000),
        ("gemini-2-5", 1_000_000),
        ("gemini-2-0", 1_000_000),
        ("gemini-1-5-pro", 2_000_000),
        ("gemini-1-5", 1_000_000),

        ("muse-spark", 1_048_576),

        ("grok-4", 256_000),
        ("grok-3", 131_072),
        ("grok-2", 131_072),

        ("o4-mini", 200_000),
        ("o3", 200_000),
        ("o1", 200_000),

        ("apple-on-device", 8_192),
        ("foundation-models", 8_192)
    ]

    private final class OverrideStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int] = [:]

        func set(_ window: Int, for id: String) {
            lock.lock()
            storage[id] = window
            lock.unlock()
        }

        func value(for id: String) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }
    }
}

import Foundation

public struct TelemetrySettings: Sendable, Hashable {
    public var isEnabled: Bool
    public var functionID: String?
    public var metadata: [String: JSONValue]
    public var includeRuntimeContext: [String]?
    public var includeToolsContext: [String]?

    public init(
        isEnabled: Bool = true,
        functionID: String? = nil,
        metadata: [String: JSONValue] = [:],
        includeRuntimeContext: [String]? = nil,
        includeToolsContext: [String]? = nil
    ) {
        self.isEnabled = isEnabled
        self.functionID = functionID
        self.metadata = metadata
        self.includeRuntimeContext = includeRuntimeContext
        self.includeToolsContext = includeToolsContext
    }

    public static let disabled = TelemetrySettings(isEnabled: false)

    func attributes(
        runtimeContext: JSONValue?,
        toolsContext: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard isEnabled else { return [:] }
        var attributes: [String: JSONValue] = [:]
        if let functionID { attributes["ai.telemetry.functionId"] = .string(functionID) }
        for (key, value) in metadata {
            attributes["ai.telemetry.metadata.\(key)"] = value
        }
        for (key, value) in Self.filter(runtimeContext, keys: includeRuntimeContext) {
            attributes["ai.runtimeContext.\(key)"] = value
        }
        if let includeToolsContext {
            for name in includeToolsContext {
                guard let value = toolsContext[name] else { continue }
                attributes["ai.toolsContext.\(name)"] = value
            }
        }
        return attributes
    }

    static func filter(_ context: JSONValue?, keys: [String]?) -> [String: JSONValue] {
        guard let keys, case .object(let object)? = context else { return [:] }
        var filtered: [String: JSONValue] = [:]
        for key in keys {
            guard let value = object[key] else { continue }
            filtered[key] = value
        }
        return filtered
    }
}

public func filterActiveTools(
    _ tools: [any AIToolProtocol],
    activeTools: [String]?
) -> [any AIToolProtocol] {
    guard let activeTools else { return tools }
    return tools.filter { activeTools.contains($0.name) }
}

public func createIdGenerator(
    prefix: String? = nil,
    separator: String = "-",
    alphabet: String = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    size: Int = 16
) -> @Sendable () -> String {
    let characters = Array(alphabet)
    precondition(!characters.isEmpty, "createIdGenerator needs a non-empty alphabet")
    let length = max(size, 1)
    return { @Sendable in
        var body = ""
        body.reserveCapacity(length)
        for _ in 0..<length {
            body.append(characters.randomElement() ?? "0")
        }
        guard let prefix else { return body }
        return prefix + separator + body
    }
}

public func generateId(size: Int = 16) -> String {
    createIdGenerator(size: size)()
}

public struct GeneratedFile: Sendable, Hashable {
    public var data: Data
    public var mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }

    public var base64: String { data.base64EncodedString() }

    public var bytes: [UInt8] { [UInt8](data) }
}

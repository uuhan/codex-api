import Foundation

public struct CodexModelDescriptor: Equatable, Sendable {
    public let id: String
    public let created: Int
    public let ownedBy: String
    public let type: String
    public let displayName: String
    public let version: String
    public let description: String
    public let contextLength: Int?
    public let maxCompletionTokens: Int?
    public let supportedParameters: [String]

    public init(
        id: String,
        created: Int,
        ownedBy: String = "openai",
        type: String = "openai",
        displayName: String,
        version: String,
        description: String = "",
        contextLength: Int? = nil,
        maxCompletionTokens: Int? = nil,
        supportedParameters: [String] = ["tools"]
    ) {
        self.id = id
        self.created = created
        self.ownedBy = ownedBy
        self.type = type
        self.displayName = displayName
        self.version = version
        self.description = description
        self.contextLength = contextLength
        self.maxCompletionTokens = maxCompletionTokens
        self.supportedParameters = supportedParameters
    }

    public var openAIModelObject: JSONObject {
        var object: JSONObject = [
            "id": id,
            "object": "model",
            "created": created,
            "owned_by": ownedBy
        ]
        if !type.isEmpty {
            object["type"] = type
        }
        if !displayName.isEmpty {
            object["display_name"] = displayName
        }
        if !version.isEmpty {
            object["version"] = version
        }
        if !description.isEmpty {
            object["description"] = description
        }
        if let contextLength {
            object["context_length"] = contextLength
        }
        if let maxCompletionTokens {
            object["max_completion_tokens"] = maxCompletionTokens
        }
        if !supportedParameters.isEmpty {
            object["supported_parameters"] = supportedParameters
        }
        return object
    }

    public var anthropicModelObject: JSONObject {
        [
            "id": id,
            "type": "model",
            "display_name": displayName.isEmpty ? id : displayName,
            "created_at": Self.iso8601DateString(fromUnixTimestamp: created)
        ]
    }

    private static func iso8601DateString(fromUnixTimestamp timestamp: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

public enum CodexModelCatalog {
    public static func models(fromUpstream payload: JSONObject) throws -> [CodexModelDescriptor] {
        guard let upstreamModels = JSONHelper.array(payload["models"]) else {
            throw ProxyError.invalidJSON("models response does not contain a models array")
        }

        return upstreamModels.compactMap { value in
            guard let model = JSONHelper.object(value),
                  JSONHelper.bool(model["supported_in_api"]),
                  JSONHelper.string(model["visibility"]) != "hide",
                  let id = JSONHelper.string(model["slug"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            return CodexModelDescriptor(
                id: id,
                created: intValue(model["created"]) ?? 0,
                displayName: JSONHelper.string(model["display_name"]) ?? id,
                version: JSONHelper.string(model["version"]) ?? id,
                description: JSONHelper.string(model["description"]) ?? "",
                contextLength: intValue(model["context_window"]) ?? intValue(model["context_length"]),
                maxCompletionTokens: intValue(model["max_completion_tokens"])
            )
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}

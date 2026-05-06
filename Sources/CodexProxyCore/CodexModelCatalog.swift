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
    public static let legacyDefaultModelIDs = ["gpt-5-codex", "gpt-5.1-codex", "gpt-5.2"]

    private static let gpt52 = CodexModelDescriptor(
        id: "gpt-5.2",
        created: 1_765_440_000,
        displayName: "GPT 5.2",
        version: "gpt-5.2",
        description: "Stable version of GPT 5.2",
        contextLength: 400_000,
        maxCompletionTokens: 128_000
    )

    private static let gpt53Codex = CodexModelDescriptor(
        id: "gpt-5.3-codex",
        created: 1_770_307_200,
        displayName: "GPT 5.3 Codex",
        version: "gpt-5.3",
        description: "Stable version of GPT 5.3 Codex, The best model for coding and agentic tasks across domains.",
        contextLength: 400_000,
        maxCompletionTokens: 128_000
    )

    private static let gpt53CodexSpark = CodexModelDescriptor(
        id: "gpt-5.3-codex-spark",
        created: 1_770_912_000,
        displayName: "GPT 5.3 Codex Spark",
        version: "gpt-5.3",
        description: "Ultra-fast coding model.",
        contextLength: 128_000,
        maxCompletionTokens: 128_000
    )

    private static let gpt54 = CodexModelDescriptor(
        id: "gpt-5.4",
        created: 1_772_668_800,
        displayName: "GPT 5.4",
        version: "gpt-5.4",
        description: "Stable version of GPT 5.4",
        contextLength: 1_050_000,
        maxCompletionTokens: 128_000
    )

    private static let gpt54Mini = CodexModelDescriptor(
        id: "gpt-5.4-mini",
        created: 1_773_705_600,
        displayName: "GPT 5.4 Mini",
        version: "gpt-5.4-mini",
        description: "GPT-5.4 mini brings the strengths of GPT-5.4 to a faster, more efficient model designed for high-volume workloads.",
        contextLength: 400_000,
        maxCompletionTokens: 128_000
    )

    private static let gpt55 = CodexModelDescriptor(
        id: "gpt-5.5",
        created: 1_776_902_400,
        displayName: "GPT 5.5",
        version: "gpt-5.5",
        description: "Frontier model for complex coding, research, and real-world work.",
        contextLength: 272_000,
        maxCompletionTokens: 128_000
    )

    private static let autoReview = CodexModelDescriptor(
        id: "codex-auto-review",
        created: 1_776_902_400,
        displayName: "Codex Auto Review",
        version: "Codex Auto Review",
        description: "Automatic approval review model for Codex.",
        contextLength: 272_000,
        maxCompletionTokens: 128_000
    )

    private static let image2 = CodexModelDescriptor(
        id: "gpt-image-2",
        created: 1_704_067_200,
        displayName: "GPT Image 2",
        version: "gpt-image-2",
        supportedParameters: []
    )

    public static let freeModels = [gpt52, gpt53Codex, gpt54, gpt54Mini, autoReview, image2]
    public static let teamModels = [gpt52, gpt53Codex, gpt54, gpt54Mini, gpt55, autoReview, image2]
    public static let plusModels = [gpt52, gpt53Codex, gpt53CodexSpark, gpt54, gpt54Mini, gpt55, autoReview, image2]
    public static let proModels = plusModels

    public static var defaultModels: [CodexModelDescriptor] {
        proModels
    }

    public static var defaultModelIDs: [String] {
        defaultModels.map(\.id)
    }

    public static var defaultModelID: String {
        "gpt-5.3-codex"
    }

    public static func models(forPlanType planType: String?) -> [CodexModelDescriptor] {
        switch normalizedPlanType(planType) {
        case "free":
            return freeModels
        case "team", "business", "go":
            return teamModels
        case "plus":
            return plusModels
        case "pro":
            return proModels
        default:
            return defaultModels
        }
    }

    public static func modelIDs(forPlanType planType: String?) -> [String] {
        models(forPlanType: planType).map(\.id)
    }

    public static func models(modelIDs: [String], planType: String?) -> [CodexModelDescriptor] {
        if isAutomaticModelList(modelIDs) {
            return models(forPlanType: planType)
        }
        return modelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { modelByID[$0] ?? customModel(id: $0) }
    }

    public static func effectiveModelIDs(modelIDs: [String], planType: String?) -> [String] {
        models(modelIDs: modelIDs, planType: planType).map(\.id)
    }

    public static func isAutomaticModelList(_ modelIDs: [String]) -> Bool {
        if modelIDs.isEmpty {
            return true
        }
        let knownDefaults = [
            legacyDefaultModelIDs,
            freeModels.map(\.id),
            teamModels.map(\.id),
            plusModels.map(\.id),
            proModels.map(\.id)
        ]
        return knownDefaults.contains { sameModelIDs($0, modelIDs) }
    }

    private static let modelByID: [String: CodexModelDescriptor] = {
        var result: [String: CodexModelDescriptor] = [:]
        for model in plusModels + teamModels + freeModels {
            result[model.id] = model
        }
        return result
    }()

    private static func customModel(id: String) -> CodexModelDescriptor {
        CodexModelDescriptor(
            id: id,
            created: 0,
            displayName: id,
            version: id,
            description: "",
            contextLength: nil,
            maxCompletionTokens: nil
        )
    }

    private static func normalizedPlanType(_ planType: String?) -> String {
        (planType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sameModelIDs(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.map { $0.lowercased() } == rhs.map { $0.lowercased() }
    }
}

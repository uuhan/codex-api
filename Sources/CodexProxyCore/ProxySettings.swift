import Foundation

public struct ProxySettings: Codable, Equatable, Sendable {
    /// Codex version required for the GPT-5.6 model family to appear upstream.
    public static let defaultCodexClientVersion = "0.144.1"
    public static let codexUserAgent = codexUserAgent(for: defaultCodexClientVersion)
    public static let codexOriginator = "codex-tui"

    private static let legacyCodexUserAgent = "codex_cli_rs/0.118.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9"
    private static let legacyCodexOriginator = "codex_cli_rs"

    public var listenHost: String
    public var listenPort: UInt16
    public var upstreamBaseURL: String
    public var authToken: String
    public var refreshToken: String
    public var idToken: String
    public var accountID: String
    public var accountEmail: String
    public var tokenExpiresAt: Date?
    public var lastRefreshAt: Date?
    public var proxyKey: String
    public var codexClientVersion: String
    public var defaultUserAgent: String
    public var originator: String
    public var modelIDs: [String]
    public var injectImageGenerationTool: Bool

    private enum CodingKeys: String, CodingKey {
        case listenHost
        case listenPort
        case upstreamBaseURL
        case authToken
        case refreshToken
        case idToken
        case accountID
        case accountEmail
        case tokenExpiresAt
        case lastRefreshAt
        case proxyKey
        case codexClientVersion
        case defaultUserAgent
        case originator
        case modelIDs
        case injectImageGenerationTool
    }

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: UInt16 = 1455,
        upstreamBaseURL: String = "https://chatgpt.com/backend-api/codex",
        authToken: String = "",
        refreshToken: String = "",
        idToken: String = "",
        accountID: String = "",
        accountEmail: String = "",
        tokenExpiresAt: Date? = nil,
        lastRefreshAt: Date? = nil,
        proxyKey: String = "",
        codexClientVersion: String = ProxySettings.defaultCodexClientVersion,
        defaultUserAgent: String = ProxySettings.codexUserAgent,
        originator: String = ProxySettings.codexOriginator,
        modelIDs: [String] = CodexModelCatalog.defaultModelIDs,
        injectImageGenerationTool: Bool = true
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamBaseURL = upstreamBaseURL
        self.authToken = authToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.tokenExpiresAt = tokenExpiresAt
        self.lastRefreshAt = lastRefreshAt
        self.proxyKey = proxyKey
        self.codexClientVersion = Self.normalizedClientVersion(codexClientVersion)
        self.defaultUserAgent = defaultUserAgent
        self.originator = originator
        self.modelIDs = modelIDs
        self.injectImageGenerationTool = injectImageGenerationTool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            listenHost: try container.decodeIfPresent(String.self, forKey: .listenHost) ?? "127.0.0.1",
            listenPort: try container.decodeIfPresent(UInt16.self, forKey: .listenPort) ?? 1455,
            upstreamBaseURL: try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL) ?? "https://chatgpt.com/backend-api/codex",
            authToken: try container.decodeIfPresent(String.self, forKey: .authToken) ?? "",
            refreshToken: try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? "",
            idToken: try container.decodeIfPresent(String.self, forKey: .idToken) ?? "",
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID) ?? "",
            accountEmail: try container.decodeIfPresent(String.self, forKey: .accountEmail) ?? "",
            tokenExpiresAt: try container.decodeIfPresent(Date.self, forKey: .tokenExpiresAt),
            lastRefreshAt: try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt),
            proxyKey: try container.decodeIfPresent(String.self, forKey: .proxyKey) ?? "",
            codexClientVersion: Self.normalizedClientVersion(try container.decodeIfPresent(String.self, forKey: .codexClientVersion)),
            defaultUserAgent: Self.updatedUserAgent(try container.decodeIfPresent(String.self, forKey: .defaultUserAgent)),
            originator: Self.updatedOriginator(try container.decodeIfPresent(String.self, forKey: .originator)),
            modelIDs: try container.decodeIfPresent([String].self, forKey: .modelIDs) ?? CodexModelCatalog.defaultModelIDs,
            injectImageGenerationTool: try container.decodeIfPresent(Bool.self, forKey: .injectImageGenerationTool) ?? true
        )
    }

    public var baseURL: String {
        "http://\(listenHost):\(listenPort)"
    }

    public var openAIBaseURL: String {
        "\(baseURL)/v1"
    }

    public var codexPlanType: String {
        Self.idTokenClaims(idToken).planType
    }

    public var usesAutomaticModelCatalog: Bool {
        CodexModelCatalog.isAutomaticModelList(modelIDs)
    }

    public var effectiveModelDescriptors: [CodexModelDescriptor] {
        CodexModelCatalog.models(modelIDs: modelIDs, planType: codexPlanType)
    }

    public var effectiveModelIDs: [String] {
        effectiveModelDescriptors.map(\.id)
    }

    public var defaultModelID: String {
        let modelIDs = effectiveModelIDs
        if modelIDs.contains(CodexModelCatalog.defaultModelID) {
            return CodexModelCatalog.defaultModelID
        }
        return modelIDs.first ?? CodexModelCatalog.defaultModelID
    }

    public var normalizedUpstreamBaseURL: String {
        upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public var upstreamClientVersion: String {
        Self.normalizedClientVersion(codexClientVersion)
    }

    public var upstreamUserAgent: String {
        let userAgent = defaultUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if userAgent.isEmpty || userAgent == Self.codexUserAgent {
            return Self.codexUserAgent(for: upstreamClientVersion)
        }
        return userAgent
    }

    public var upstreamOriginator: String {
        let value = originator.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.codexOriginator : value
    }

    public var hasOAuthSession: Bool {
        !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func applyOAuthTokens(_ tokens: CodexOAuthTokenBundle) {
        authToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        idToken = tokens.idToken
        accountID = tokens.accountID
        accountEmail = tokens.email
        tokenExpiresAt = tokens.expiresAt
        lastRefreshAt = tokens.lastRefreshAt
    }

    public mutating func clearOAuthTokens() {
        authToken = ""
        refreshToken = ""
        idToken = ""
        accountID = ""
        accountEmail = ""
        tokenExpiresAt = nil
        lastRefreshAt = nil
    }

    public static func idTokenClaims(_ token: String) -> (accountID: String, email: String, planType: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = base64URLDecode(String(parts[1])),
              let object = try? JSONHelper.object(from: payload) else {
            return ("", "", "")
        }
        let auth = JSONHelper.object(object["https://api.openai.com/auth"])
        return (
            JSONHelper.string(auth?["chatgpt_account_id"]) ?? "",
            JSONHelper.string(object["email"]) ?? "",
            JSONHelper.string(auth?["chatgpt_plan_type"]) ?? ""
        )
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var string = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = string.count % 4
        if remainder > 0 {
            string += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: string)
    }

    private static func updatedUserAgent(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case nil, "", legacyCodexUserAgent:
            return codexUserAgent
        case let value?:
            return value
        }
    }

    private static func updatedOriginator(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case nil, "", legacyCodexOriginator:
            return codexOriginator
        case let value?:
            return value
        }
    }

    public static func codexUserAgent(for clientVersion: String) -> String {
        "codex-tui/\(clientVersion) (Mac OS 26.5.0; arm64) iTerm.app/3.6.10 (codex-tui; \(clientVersion))"
    }

    private static func normalizedClientVersion(_ value: String?) -> String {
        let version = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? defaultCodexClientVersion : version
    }
}

public final class SettingsStore {
    private enum Key {
        static let settings = "codex-api.settings.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ProxySettings {
        guard let data = defaults.data(forKey: Key.settings),
              let settings = try? decoder.decode(ProxySettings.self, from: data) else {
            return ProxySettings()
        }
        return settings
    }

    public func save(_ settings: ProxySettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        defaults.set(data, forKey: Key.settings)
    }
}

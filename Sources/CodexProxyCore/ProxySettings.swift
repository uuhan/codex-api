import Foundation

public struct ProxySettings: Codable, Equatable, Sendable {
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
        defaultUserAgent: String = "codex_cli_rs/0.118.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9",
        originator: String = "codex_cli_rs",
        modelIDs: [String] = ["gpt-5-codex", "gpt-5.1-codex", "gpt-5.2"],
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
            defaultUserAgent: try container.decodeIfPresent(String.self, forKey: .defaultUserAgent) ?? "codex_cli_rs/0.118.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9",
            originator: try container.decodeIfPresent(String.self, forKey: .originator) ?? "codex_cli_rs",
            modelIDs: try container.decodeIfPresent([String].self, forKey: .modelIDs) ?? ["gpt-5-codex", "gpt-5.1-codex", "gpt-5.2"],
            injectImageGenerationTool: try container.decodeIfPresent(Bool.self, forKey: .injectImageGenerationTool) ?? true
        )
    }

    public var baseURL: String {
        "http://\(listenHost):\(listenPort)"
    }

    public var openAIBaseURL: String {
        "\(baseURL)/v1"
    }

    public var normalizedUpstreamBaseURL: String {
        upstreamBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

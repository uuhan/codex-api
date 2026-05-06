import CryptoKit
import Foundation
import Security

public struct CodexOAuthTokenBundle: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String
    public var accountID: String
    public var email: String
    public var expiresAt: Date
    public var lastRefreshAt: Date

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String,
        accountID: String,
        email: String,
        expiresAt: Date,
        lastRefreshAt: Date = Date()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.email = email
        self.expiresAt = expiresAt
        self.lastRefreshAt = lastRefreshAt
    }
}

public final class CodexOAuthService: @unchecked Sendable {
    public static let authURL = "https://auth.openai.com/oauth/authorize"
    public static let tokenURL = "https://auth.openai.com/oauth/token"
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private struct PendingLogin {
        let state: String
        let codeVerifier: String
        let redirectURI: String
        let createdAt: Date
    }

    private let session: URLSession
    private let lock = NSLock()
    private var pending: PendingLogin?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func redirectURI(for settings: ProxySettings) -> String {
        "http://localhost:\(settings.listenPort)/auth/callback"
    }

    public func beginLogin(redirectURI: String) throws -> URL {
        let verifier = try generateCodeVerifier()
        let challenge = codeChallenge(for: verifier)
        let state = try randomBase64URL(byteCount: 32)

        var components = URLComponents(string: Self.authURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email profile offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "login"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true")
        ]

        guard let url = components?.url else {
            throw ProxyError.network("failed to build OAuth authorization URL")
        }

        lock.lock()
        pending = PendingLogin(state: state, codeVerifier: verifier, redirectURI: redirectURI, createdAt: Date())
        lock.unlock()

        return url
    }

    public func handleCallback(query: String?) async throws -> CodexOAuthTokenBundle {
        let items = queryItems(query)
        if let error = items["error"], !error.isEmpty {
            let description = items["error_description"] ?? error
            throw ProxyError.badRequest(description)
        }

        guard let code = items["code"], !code.isEmpty else {
            throw ProxyError.badRequest("OAuth callback is missing code")
        }
        guard let state = items["state"], !state.isEmpty else {
            throw ProxyError.badRequest("OAuth callback is missing state")
        }

        let login = try consumePendingLogin(state: state)
        return try await exchangeCode(code, codeVerifier: login.codeVerifier, redirectURI: login.redirectURI)
    }

    public func refreshTokens(refreshToken: String) async throws -> CodexOAuthTokenBundle {
        guard !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProxyError.badRequest("refresh token is empty")
        }
        let form: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ]
        return try await tokenRequest(form: form, fallbackRefreshToken: refreshToken)
    }

    private func exchangeCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> CodexOAuthTokenBundle {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ]
        return try await tokenRequest(form: form, fallbackRefreshToken: "")
    }

    private func tokenRequest(form: [String: String], fallbackRefreshToken: String) async throws -> CodexOAuthTokenBundle {
        guard let url = URL(string: Self.tokenURL) else {
            throw ProxyError.network("invalid OAuth token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncoded(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.network("OAuth token endpoint did not return HTTP")
        }
        guard http.statusCode == 200 else {
            throw ProxyError.upstreamStatus(http.statusCode, data)
        }

        let object = try JSONHelper.object(from: data)
        guard let accessToken = JSONHelper.string(object["access_token"]), !accessToken.isEmpty else {
            throw ProxyError.badRequest("OAuth token response is missing access_token")
        }
        let refreshToken = JSONHelper.string(object["refresh_token"]) ?? fallbackRefreshToken
        let idToken = JSONHelper.string(object["id_token"]) ?? ""
        let expiresIn = secondsValue(object["expires_in"]) ?? 3600
        let claims = parseIDToken(idToken)

        return CodexOAuthTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: claims.accountID,
            email: claims.email,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            lastRefreshAt: Date()
        )
    }

    private func consumePendingLogin(state: String) throws -> PendingLogin {
        lock.lock()
        defer { lock.unlock() }

        guard let pending else {
            throw ProxyError.badRequest("OAuth login was not initiated")
        }
        guard pending.state == state else {
            throw ProxyError.badRequest("OAuth state mismatch")
        }
        guard Date().timeIntervalSince(pending.createdAt) < 10 * 60 else {
            self.pending = nil
            throw ProxyError.badRequest("OAuth login expired")
        }

        self.pending = nil
        return pending
    }

    private func queryItems(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else {
            return [:]
        }
        var components = URLComponents()
        components.percentEncodedQuery = query
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private func formURLEncoded(_ form: [String: String]) -> String {
        form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public func parseIDToken(_ token: String) -> (accountID: String, email: String, planType: String) {
        ProxySettings.idTokenClaims(token)
    }

    private func generateCodeVerifier() throws -> String {
        try randomBase64URL(byteCount: 96)
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProxyError.network("secure random generation failed")
        }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func secondsValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}

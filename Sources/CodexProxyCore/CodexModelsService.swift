import Foundation

public final class CodexModelsService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(settings: ProxySettings) async throws -> [CodexModelDescriptor] {
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ProxyError.missingUpstreamToken
        }

        let request = try Self.makeRequest(settings: settings, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProxyError.network(UpstreamClient.transportErrorMessage(error, url: request.url))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.network("models endpoint did not return HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProxyError.upstreamStatus(http.statusCode, data)
        }
        return try CodexModelCatalog.models(fromUpstream: JSONHelper.object(from: data))
    }

    static func makeRequest(settings: ProxySettings, token: String) throws -> URLRequest {
        guard var components = URLComponents(string: settings.normalizedUpstreamBaseURL + "/models") else {
            throw ProxyError.badRequest("invalid upstream URL")
        }
        components.queryItems = [URLQueryItem(name: "client_version", value: settings.upstreamClientVersion)]
        guard let url = components.url else {
            throw ProxyError.badRequest("invalid upstream URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.upstreamUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(settings.upstreamOriginator, forHTTPHeaderField: "Originator")
        if !settings.accountID.isEmpty {
            request.setValue(settings.accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
        }
        return request
    }
}

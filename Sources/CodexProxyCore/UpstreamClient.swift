import Foundation

struct UpstreamResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct UpstreamStream {
    let statusCode: Int
    let headers: [String: String]
    let bytes: URLSession.AsyncBytes
}

final class UpstreamClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(settings: ProxySettings, request: HTTPRequest, path: String, body: JSONObject, stream: Bool) async throws -> UpstreamResponse {
        var upstreamRequest = try makeRequest(settings: settings, request: request, path: path, body: body, stream: stream)
        upstreamRequest.timeoutInterval = 600
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: upstreamRequest)
        } catch {
            throw ProxyError.network(Self.transportErrorMessage(error, url: upstreamRequest.url))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.network("upstream did not return HTTP response")
        }
        return UpstreamResponse(statusCode: http.statusCode, headers: responseHeaders(http), body: data)
    }

    func stream(settings: ProxySettings, request: HTTPRequest, path: String, body: JSONObject) async throws -> UpstreamStream {
        let upstreamRequest = try makeRequest(settings: settings, request: request, path: path, body: body, stream: true)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: upstreamRequest)
        } catch {
            throw ProxyError.network(Self.transportErrorMessage(error, url: upstreamRequest.url))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.network("upstream did not return HTTP response")
        }
        return UpstreamStream(statusCode: http.statusCode, headers: responseHeaders(http), bytes: bytes)
    }

    private func makeRequest(settings: ProxySettings, request: HTTPRequest, path: String, body: JSONObject, stream: Bool) throws -> URLRequest {
        guard let url = URL(string: settings.normalizedUpstreamBaseURL + path) else {
            throw ProxyError.badRequest("invalid upstream URL")
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = "POST"
        upstream.httpBody = try JSONHelper.data(body)
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        upstream.setValue("Keep-Alive", forHTTPHeaderField: "Connection")

        if let token = upstreamToken(settings: settings, request: request), !token.isEmpty {
            upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw ProxyError.missingUpstreamToken
        }

        let userAgent = request.header("user-agent") ?? settings.defaultUserAgent
        upstream.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if let beta = request.header("x-codex-beta-features"), !beta.isEmpty {
            upstream.setValue(beta, forHTTPHeaderField: "X-Codex-Beta-Features")
        }
        copyHeader("version", from: request, to: &upstream, as: "Version")
        copyHeader("x-codex-turn-metadata", from: request, to: &upstream, as: "X-Codex-Turn-Metadata")
        copyHeader("x-client-request-id", from: request, to: &upstream, as: "X-Client-Request-Id")

        let sessionID = request.header("session_id") ?? request.header("x-session-id") ?? UUID().uuidString
        upstream.setValue(sessionID, forHTTPHeaderField: "Session_id")

        if let originator = request.header("originator"), !originator.isEmpty {
            upstream.setValue(originator, forHTTPHeaderField: "Originator")
        } else if !settings.originator.isEmpty {
            upstream.setValue(settings.originator, forHTTPHeaderField: "Originator")
        }

        if !settings.accountID.isEmpty {
            upstream.setValue(settings.accountID, forHTTPHeaderField: "Chatgpt-Account-Id")
        }
        return upstream
    }

    private func upstreamToken(settings: ProxySettings, request: HTTPRequest) -> String? {
        if !settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !settings.proxyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return request.bearerToken
    }

    private func copyHeader(_ name: String, from request: HTTPRequest, to upstream: inout URLRequest, as upstreamName: String) {
        guard let value = request.header(name), !value.isEmpty else {
            return
        }
        upstream.setValue(value, forHTTPHeaderField: upstreamName)
    }

    private func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else {
                continue
            }
            let lower = name.lowercased()
            if ["content-type", "retry-after", "x-request-id", "openai-processing-ms"].contains(lower) {
                headers[name] = "\(value)"
            }
        }
        return headers
    }

    static func transportErrorMessage(_ error: Error, url: URL?) -> String {
        let destination = url?.host.map { " connecting to \($0)" } ?? ""
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .serverCertificateUntrusted,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return "upstream TLS error\(destination): \(urlError.localizedDescription)"
            default:
                return "upstream network error\(destination): \(urlError.localizedDescription)"
            }
        }
        return "upstream network error\(destination): \(error.localizedDescription)"
    }
}

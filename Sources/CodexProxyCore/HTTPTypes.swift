import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let path: String
    public let query: String?
    public let version: String
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var bearerToken: String? {
        guard let value = header("authorization") else {
            return nil
        }
        let prefix = "bearer "
        guard value.lowercased().hasPrefix(prefix) else {
            return nil
        }
        return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
        self.body = body
    }
}

enum HTTPParser {
    static func parseRequest(from data: Data) throws -> HTTPRequest {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else {
            throw ProxyError.badRequest("missing HTTP header terminator")
        }
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw ProxyError.badRequest("headers are not valid UTF-8")
        }

        let lines = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let requestLine = lines.first else {
            throw ProxyError.badRequest("empty request")
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else {
            throw ProxyError.badRequest("invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let target = requestParts[1]
        let path: String
        let query: String?
        if let question = target.firstIndex(of: "?") {
            path = String(target[..<question])
            query = String(target[target.index(after: question)...])
        } else {
            path = target
            query = nil
        }

        let bodyStart = headerRange.upperBound
        let body = bodyStart < data.endIndex ? Data(data[bodyStart...]) : Data()
        return HTTPRequest(
            method: requestParts[0].uppercased(),
            target: target,
            path: path,
            query: query,
            version: requestParts[2],
            headers: headers,
            body: body
        )
    }

    static func contentLength(in data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        for line in headerText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else {
                continue
            }
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return 0
    }

    static func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)),
              let contentLength = contentLength(in: data) else {
            return false
        }
        let bodyStart = headerRange.upperBound
        return data.count - bodyStart >= contentLength
    }

    static func serializeResponse(_ response: HTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = headers["Connection"] ?? "close"
        headers["Access-Control-Allow-Origin"] = headers["Access-Control-Allow-Origin"] ?? "*"
        headers["Access-Control-Allow-Headers"] = headers["Access-Control-Allow-Headers"] ?? "authorization, content-type, x-api-key, anthropic-version, anthropic-beta, x-codex-beta-features, x-codex-turn-metadata, x-client-request-id, session_id, version, originator"
        headers["Access-Control-Allow-Methods"] = headers["Access-Control-Allow-Methods"] ?? "GET, POST, OPTIONS"

        var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    static func streamHeader(statusCode: Int = 200, reason: String = "OK", headers: [String: String]) -> Data {
        var merged = headers
        merged["Connection"] = merged["Connection"] ?? "close"
        merged["Access-Control-Allow-Origin"] = merged["Access-Control-Allow-Origin"] ?? "*"
        merged["Access-Control-Allow-Headers"] = merged["Access-Control-Allow-Headers"] ?? "authorization, content-type, x-api-key, anthropic-version, anthropic-beta, x-codex-beta-features, x-codex-turn-metadata, x-client-request-id, session_id, version, originator"
        merged["Access-Control-Allow-Methods"] = merged["Access-Control-Allow-Methods"] ?? "GET, POST, OPTIONS"

        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for (name, value) in merged.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}

public enum ProxyError: Error, CustomStringConvertible, Sendable {
    case badRequest(String)
    case unauthorized
    case notFound
    case upstreamStatus(Int, Data)
    case invalidJSON(String)
    case missingUpstreamToken
    case network(String)

    public var description: String {
        switch self {
        case .badRequest(let message):
            return message
        case .unauthorized:
            return "unauthorized"
        case .notFound:
            return "not found"
        case .upstreamStatus(let status, let body):
            let text = String(data: body, encoding: .utf8) ?? ""
            return "upstream returned \(status): \(text)"
        case .invalidJSON(let message):
            return "invalid JSON: \(message)"
        case .missingUpstreamToken:
            return "missing upstream Codex token"
        case .network(let message):
            return message
        }
    }
}

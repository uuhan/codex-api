import Foundation

public struct CodexRateLimits: Equatable, Sendable {
    public var snapshots: [CodexRateLimitSnapshot]

    public init(snapshots: [CodexRateLimitSnapshot]) {
        self.snapshots = snapshots
    }

    public var codexSnapshot: CodexRateLimitSnapshot? {
        snapshots.first { $0.limitID == "codex" } ?? snapshots.first
    }
}

public struct CodexRateLimitSnapshot: Equatable, Sendable, Identifiable {
    public var limitID: String?
    public var limitName: String?
    public var primary: CodexRateLimitWindow?
    public var secondary: CodexRateLimitWindow?
    public var planType: String?
    public var rateLimitReachedType: String?

    public var id: String {
        limitID ?? limitName ?? "codex"
    }

    public init(
        limitID: String?,
        limitName: String?,
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        planType: String?,
        rateLimitReachedType: String?
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct CodexRateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var windowDurationMinutes: Int?
    public var resetAfterSeconds: Int?
    public var resetsAt: Date?

    public init(
        usedPercent: Double,
        windowDurationMinutes: Int?,
        resetAfterSeconds: Int?,
        resetsAt: Date?
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetAfterSeconds = resetAfterSeconds
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        (100 - usedPercent).clamped(to: 0...100)
    }

    public var displayName: String {
        guard let minutes = windowDurationMinutes, minutes > 0 else {
            return "Limit"
        }
        if minutes % (7 * 24 * 60) == 0 {
            let weeks = minutes / (7 * 24 * 60)
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        if minutes % (24 * 60) == 0 {
            let days = minutes / (24 * 60)
            return days == 1 ? "1 day" : "\(days) days"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }
}

public final class CodexRateLimitService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(settings: ProxySettings) async throws -> CodexRateLimits {
        guard let url = URL(string: Self.rateLimitsURL(for: settings.upstreamBaseURL)) else {
            throw ProxyError.badRequest("invalid rate limits URL")
        }
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ProxyError.missingUpstreamToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.upstreamUserAgent, forHTTPHeaderField: "User-Agent")
        if !settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(settings.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProxyError.network(UpstreamClient.transportErrorMessage(error, url: url))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.network("rate limits endpoint did not return HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProxyError.upstreamStatus(http.statusCode, data)
        }

        let payload = try JSONHelper.object(from: data)
        return CodexRateLimits(snapshots: Self.snapshots(from: payload))
    }

    static func rateLimitsURL(for upstreamBaseURL: String) -> String {
        let trimmed = upstreamBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let range = trimmed.range(of: "/backend-api") {
            let backendBase = String(trimmed[..<range.upperBound])
            return "\(backendBase)/wham/usage"
        }
        if trimmed.hasSuffix("/api/codex") {
            return "\(trimmed)/usage"
        }
        return "\(trimmed)/api/codex/usage"
    }

    static func snapshots(from payload: JSONObject) -> [CodexRateLimitSnapshot] {
        let planType = JSONHelper.string(payload["plan_type"])
        let reachedType = JSONHelper.string(JSONHelper.object(payload["rate_limit_reached_type"])?["type"])
        var snapshots = [
            snapshot(
                limitID: "codex",
                limitName: nil,
                rateLimit: JSONHelper.object(payload["rate_limit"]),
                planType: planType,
                rateLimitReachedType: reachedType
            )
        ]

        for item in JSONHelper.array(payload["additional_rate_limits"]) ?? [] {
            guard let object = JSONHelper.object(item) else {
                continue
            }
            snapshots.append(
                snapshot(
                    limitID: JSONHelper.string(object["metered_feature"]),
                    limitName: JSONHelper.string(object["limit_name"]),
                    rateLimit: JSONHelper.object(object["rate_limit"]),
                    planType: planType,
                    rateLimitReachedType: nil
                )
            )
        }
        return snapshots
    }

    private static func snapshot(
        limitID: String?,
        limitName: String?,
        rateLimit: JSONObject?,
        planType: String?,
        rateLimitReachedType: String?
    ) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            limitID: limitID,
            limitName: limitName,
            primary: window(from: JSONHelper.object(rateLimit?["primary_window"])),
            secondary: window(from: JSONHelper.object(rateLimit?["secondary_window"])),
            planType: planType,
            rateLimitReachedType: rateLimitReachedType
        )
    }

    private static func window(from object: JSONObject?) -> CodexRateLimitWindow? {
        guard let object, let usedPercent = doubleValue(object["used_percent"]) else {
            return nil
        }
        let seconds = intValue(object["limit_window_seconds"])
        let resetEpoch = doubleValue(object["reset_at"])
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: seconds.map { $0 / 60 },
            resetAfterSeconds: intValue(object["reset_after_seconds"]),
            resetsAt: resetEpoch.map { Date(timeIntervalSince1970: $0) }
        )
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

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

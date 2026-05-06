import Foundation

public enum ProxyLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct ProxyLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: ProxyLogLevel
    public let message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: ProxyLogLevel, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public final class ProxyLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProxyLogEntry] = []
    private let capacity: Int
    public var onChange: (@Sendable ([ProxyLogEntry]) -> Void)?

    public init(capacity: Int = 300) {
        self.capacity = capacity
    }

    public func append(_ level: ProxyLogLevel, _ message: String) {
        let snapshot: [ProxyLogEntry]
        lock.lock()
        entries.append(ProxyLogEntry(level: level, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        snapshot = entries
        lock.unlock()
        onChange?(snapshot)
    }

    public func snapshot() -> [ProxyLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}


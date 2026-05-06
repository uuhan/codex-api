import Foundation

public typealias JSONObject = [String: Any]
public typealias JSONArray = [Any]

enum JSONHelper {
    static func object(from data: Data) throws -> JSONObject {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
                throw ProxyError.invalidJSON("expected top-level object")
            }
            return object
        } catch let error as ProxyError {
            throw error
        } catch {
            throw ProxyError.invalidJSON(error.localizedDescription)
        }
    }

    static func data(_ value: Any, pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ProxyError.invalidJSON("object cannot be serialized")
        }
        return try JSONSerialization.data(withJSONObject: value, options: options)
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        default:
            return false
        }
    }

    static func object(_ value: Any?) -> JSONObject? {
        value as? JSONObject
    }

    static func array(_ value: Any?) -> JSONArray? {
        value as? JSONArray
    }

    static func nullIfEmpty(_ value: String?) -> Any {
        guard let value, !value.isEmpty else {
            return NSNull()
        }
        return value
    }

    static func compactString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return text
    }
}

extension Dictionary where Key == String, Value == Any {
    mutating func removeKeys(_ keys: [String]) {
        for key in keys {
            removeValue(forKey: key)
        }
    }
}

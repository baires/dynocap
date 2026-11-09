import Foundation

public enum NetworkMode: String, Codable {
    case none
    case nat
}

public enum IsolationPolicy {
    public static let version = 1
    public static let defaultTTL = 1800
    public static let maximumTTL = 86400

    public static func ttl(_ requested: Int?) throws -> Int {
        let value = requested ?? defaultTTL
        guard (1...maximumTTL).contains(value) else {
            throw MicroVMError("ttlSeconds must be an integer between 1 and 86400 (default 1800)")
        }
        return value
    }
}

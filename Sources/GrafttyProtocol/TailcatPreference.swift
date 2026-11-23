import Foundation

public enum TailcatPreference {
    public static let key = "remote.useTailcat"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Delivered only over a paired SSH channel. The address contains a shared secret.
public struct TailcatEndpoint: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: String
    public let port: UInt16
    public var description: String { "TailcatEndpoint(redacted)" }
    public var debugDescription: String { description }

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

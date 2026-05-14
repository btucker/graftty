import Foundation

public struct PushDevice: Codable, Sendable, Equatable {
    public let token: String
    public let deviceName: String
    public let platform: String  // "ios" today; "macos" reserved for future cross-push
    public let lastRegisteredAt: Date

    public init(token: String, deviceName: String, platform: String, lastRegisteredAt: Date) {
        self.token = token
        self.deviceName = deviceName
        self.platform = platform
        self.lastRegisteredAt = lastRegisteredAt
    }
}

extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

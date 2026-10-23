import Foundation

/// Provider event identifiers are opaque. Drain and recovery code use the
/// deadline and action without interpreting EC2 IDs or provider metadata.
public struct HostInterruptionNotice: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case stop, terminate, hibernate }
    public let provider: String
    public let eventID: String
    public let action: Action
    public let deadline: Date

    public init(provider: String, eventID: String, action: Action, deadline: Date) {
        self.provider = provider; self.eventID = eventID; self.action = action; self.deadline = deadline
    }

    public func validate() throws {
        guard provider.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
              !eventID.isEmpty, eventID.utf8.count <= 512,
              !eventID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              deadline.timeIntervalSince1970.isFinite else { throw ProviderError("Invalid interruption notice") }
    }
}

public protocol HostInterruptionSource: Sendable {
    /// nil means a successful observation with no notice. An unavailable or
    /// malformed response throws; it must not clear an already observed drain.
    func poll() async throws -> HostInterruptionNotice?
}

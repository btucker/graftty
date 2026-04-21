import Foundation

public struct PRInfo: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case open
        case merged
    }

    public enum Checks: String, Codable, Sendable, Equatable {
        case pending
        case success
        case failure
        case none
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let checks: Checks
    public let fetchedAt: Date

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        state: State,
        checks: Checks,
        fetchedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.fetchedAt = fetchedAt
    }

    /// `fetchedAt` is excluded from equality so change-guards on the
    /// observable store don't trigger re-renders every poll when the
    /// semantic PR state hasn't changed.
    public static func == (lhs: PRInfo, rhs: PRInfo) -> Bool {
        lhs.number == rhs.number &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.state == rhs.state &&
        lhs.checks == rhs.checks
    }
}

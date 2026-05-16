import Foundation

public enum HostingProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case github
    case gitlab
    case unsupported
}

import Foundation

public enum HostingProvider: String, Codable, Sendable, Equatable {
    case github
    case gitlab
    case unsupported
}

import Foundation

public struct HostingOrigin: Codable, Sendable, Equatable {
    public let provider: HostingProvider
    public let host: String
    public let owner: String
    public let repo: String

    public init(provider: HostingProvider, host: String, owner: String, repo: String) {
        self.provider = provider
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    public var slug: String { "\(owner)/\(repo)" }
}

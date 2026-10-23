import Foundation

public struct HostProviderBinding: Codable, Sendable, Equatable {
    public let provider: String
    public let operationID: UUID

    public init(provider: String, operationID: UUID) {
        self.provider = provider
        self.operationID = operationID
    }
}

public enum HostProviderTransport: Sendable, Equatable {
    case directSSH(host: String, port: Int)
    case proxy(command: String, arguments: [String])
}

/// Prepared by a locally registered adapter. The transport target is not proof
/// of identity: callers must pin SSH to the returned public key.
public struct HostProviderConnection: Sendable, Equatable {
    public let binding: HostProviderBinding
    public let target: String
    public let identity: LinuxHostIdentity
    public let transport: HostProviderTransport

    public init(binding: HostProviderBinding, target: String, identity: LinuxHostIdentity, transport: HostProviderTransport) {
        self.binding = binding
        self.target = target
        self.identity = identity
        self.transport = transport
    }
}

/// Adapters own provider credentials, enrollment records, and transport setup.
/// Authorization must consult current local trust, not just a cached plan.
public protocol HostProvider: Sendable {
    var identifier: String { get }
    func prepareConnection(operationID: UUID, parent: LinuxHostTrustRequest) async throws -> HostProviderConnection
    func authorize(_ connection: HostProviderConnection, parent: LinuxHostTrustRequest) throws
}

public struct HostProviderRegistry: Sendable {
    private let providers: [String: any HostProvider]

    public init(providers: [any HostProvider]) throws {
        var registered: [String: any HostProvider] = [:]
        for provider in providers {
            guard provider.identifier.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  registered[provider.identifier] == nil else {
                throw ProviderError("Provider identifiers must be unique lowercase names.")
            }
            registered[provider.identifier] = provider
        }
        self.providers = registered
    }

    public func prepareConnection(binding: HostProviderBinding, parent: LinuxHostTrustRequest) async throws -> HostProviderConnection {
        try Task.checkCancellation()
        let connection = try await adapter(binding).prepareConnection(operationID: binding.operationID, parent: parent)
        guard connection.binding == binding else { throw ProviderError("Provider returned a different enrollment binding.") }
        try authorize(connection, parent: parent)
        return connection
    }

    public func authorize(_ connection: HostProviderConnection, parent: LinuxHostTrustRequest) throws {
        try Task.checkCancellation()
        try connection.identity.validate()
        try adapter(connection.binding).authorize(connection, parent: parent)
    }

    private func adapter(_ binding: HostProviderBinding) throws -> any HostProvider {
        guard let provider = providers[binding.provider] else { throw ProviderError("Unknown compute provider: \(binding.provider)") }
        return provider
    }
}

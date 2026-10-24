import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// One authenticated attempt. The supervisor owns retry and persistence; this
/// runner owns the channels and subprocesses it creates and never resends MCP requests.
enum ParentMCPConnection {
    static func run(_ configuration: MCPConnectionConfiguration, registry: HostProviderRegistry,
                    processScope: DuplexSubprocessScope = .init(),
                    existingConnection: @escaping @Sendable (RemoteMacConnectionSummary.ID) async throws -> (any MCPHostLink)? = { _ in nil },
                    identity: @escaping @Sendable () async throws -> (LinuxHostTrustRequest, Curve25519.Signing.PrivateKey),
                    ready: @escaping @Sendable () async -> Void) async throws {
        let parent: LinuxHostTrustRequest
        let key: Curve25519.Signing.PrivateKey
        let file = URL(fileURLWithPath: configuration.policyPath)
        do {
            (parent, key) = try await identity()
            guard key.publicKey.rawRepresentation.base64EncodedString() == parent.publicKey else {
                throw MCPConnectionFailure.authorization
            }
            try parent.validate()
            _ = try MCPProxyPolicy.load(from: file)
        } catch { throw MCPConnectionFailure.authorization }
        let plan: HostProviderConnection
        do { plan = try await registry.prepareConnection(binding: .init(provider: configuration.provider, operationID: configuration.operationID), parent: parent) }
        catch HostProviderConnectionError.authorization { throw MCPConnectionFailure.authorization }
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: Data(base64Encoded: plan.identity.publicKey) ?? Data())
        let fingerprint = RemoteIdentityFingerprint(of: publicKey)
        let peer = RemoteMacConnectionSummary.ID(deviceID: .init(value: plan.identity.deviceID), fingerprint: fingerprint)
        // The app registry matches both device ID and pinned key before lending
        // a link. Never replace its state observer or close a borrowed transport.
        let existing = try await existingConnection(peer)
        try Task.checkCancellation()
        let owned: DirectSSHHostConnection?
        let connection: any MCPHostLink
        if let existing { owned = nil; connection = existing }
        else {
            let fresh = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
            owned = fresh; connection = fresh
        }
        let broker = MCPProxyBroker(peer: peer, authorize: { scope, peer in
            try registry.authorize(plan, parent: parent)
            return try MCPProxyPolicy.load(from: file).authorize(scope, peer: peer)
        }, makeTransport: { try await MCPProxyUpstream.open($0, processScope: processScope) })
        var proxy: DuplexSubprocess?
        do {
            if let owned {
                switch plan.transport {
                case .directSSH(let host, let port): try await owned.connect(host: host, port: port)
                case .proxy(let command, let arguments):
                    let process = try processScope.launch { try DuplexSubprocess(command: command, arguments: arguments) }
                    proxy = process
                    try await owned.connect(input: process.output, output: process.input)
                }
            }
            try registry.authorize(plan, parent: parent)
            let channel = try await connection.makeMCPControlClient(handler: { await broker.handle($0) }, onClose: { await broker.close() })
            // Retain the RPC client's weak transport callbacks for this attempt.
            defer { channel.close() }
            try await channel.open()
            guard try await channel.send(MCPProxyControl.ready) == MCPProxyControl.ready else { throw MCPConnectionFailure.unavailable }
            try Task.checkCancellation()
            await ready()
            while true {
                try Task.checkCancellation()
                try registry.authorize(plan, parent: parent)
                do {
                    let (current, currentKey) = try await identity()
                    guard current == parent, currentKey.publicKey.rawRepresentation == key.publicKey.rawRepresentation else {
                        throw MCPConnectionFailure.authorization
                    }
                    _ = try MCPProxyPolicy.load(from: file)
                } catch { throw MCPConnectionFailure.authorization }
                guard await connection.state == .connected, !(await broker.isClosed) else { throw MCPConnectionFailure.unavailable }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            await broker.close(); await owned?.close(); await proxy?.stop()
            if case HostProviderConnectionError.authorization = error { throw MCPConnectionFailure.authorization }
            throw error
        }
    }
}

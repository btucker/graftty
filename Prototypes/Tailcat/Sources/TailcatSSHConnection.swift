import CryptoKit
import GrafttyProtocol
import GrafttyRemoteClient

public final class TailcatSSHConnection: @unchecked Sendable {
    public let ssh: DirectSSHHostConnection
    private let peer: TailcatPeer
    private let pipe: TailcatPipe
    private init(ssh: DirectSSHHostConnection, peer: TailcatPeer, pipe: TailcatPipe) {
        self.ssh = ssh; self.peer = peer; self.pipe = pipe
    }
    public static func connect(address: String, port: UInt16, key: Curve25519.Signing.PrivateKey,
                               fingerprint: RemoteIdentityFingerprint) async throws -> TailcatSSHConnection {
        let peer = try TailcatPeer.client(address: address)
        let pipe: TailcatPipe
        do { pipe = try await peer.dial(port: port) }
        catch { await peer.close(); throw error }
        let ssh = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
        do {
            try await ssh.connect(input: pipe.file, output: pipe.file)
            try pipe.file.close()
            try Task.checkCancellation()
            return TailcatSSHConnection(ssh: ssh, peer: peer, pipe: pipe)
        } catch {
            await ssh.close(); await pipe.close(); await peer.close()
            throw error
        }
    }
    public func routeKind() async throws -> String { try await peer.routeKind() }
    public func close() async {
        await ssh.close(); await pipe.close(); await peer.close()
    }
}

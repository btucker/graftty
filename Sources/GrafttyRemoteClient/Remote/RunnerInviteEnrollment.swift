#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol

/// Redeems a runner invite: connects pinned to the invite's host key while
/// signing with this Mac's key and sending the enrollment token as the SSH
/// username. The runner trusts the key on success; the connection then closes.
public enum RunnerInviteEnrollment {
    public static func enroll(
        hostPublicKey: RemoteIdentityPublicKey,
        enrollmentUsername: String,
        clientKey: Curve25519.Signing.PrivateKey,
        connect: @Sendable (DirectSSHHostConnection) async throws -> Void
    ) async throws {
        let connection = DirectSSHHostConnection(clientKey: clientKey,
            expectedHostFingerprint: RemoteIdentityFingerprint(of: hostPublicKey), username: enrollmentUsername)
        do { try await connect(connection) } catch { await connection.close(); throw error }
        await connection.close()
    }

    #if canImport(GrafttyTailcat)
    /// Redeems over the runner's Tailcat endpoint.
    public static func enroll(
        hostPublicKey: RemoteIdentityPublicKey,
        enrollmentUsername: String,
        clientKey: Curve25519.Signing.PrivateKey,
        endpoint: TailcatEndpoint
    ) async throws {
        try await enroll(hostPublicKey: hostPublicKey, enrollmentUsername: enrollmentUsername, clientKey: clientKey) {
            try await $0.connect(tailcat: endpoint)
        }
    }
    #endif
}

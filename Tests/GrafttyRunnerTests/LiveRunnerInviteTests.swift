#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

/// Redeems a real runner's invite over Tailcat, then reconnects with the
/// enrolled key. Opt in with GRAFTTY_TEST_RUNNER_INVITE set to a fresh line
/// from graftty-runner invite; add TS_DEBUG_ALWAYS_USE_DERP=true to force the
/// relay. The invite is never printed.
struct LiveRunnerInviteTests {
    private static let invite = ProcessInfo.processInfo.environment["GRAFTTY_TEST_RUNNER_INVITE"]

    @Test(.enabled(if: invite != nil), .timeLimit(.minutes(2)))
    func redeemsAndReconnectsOverTailcat() async throws {
        let invite = try RunnerInvite(parsing: #require(Self.invite))
        let hostKey = try RemoteIdentityPublicKey(rawRepresentation: #require(Data(base64Encoded: invite.identity.publicKey)))
        let clientKey = Curve25519.Signing.PrivateKey()
        let token = RunnerEnrollmentToken(secret: invite.secret, deviceID: "live-test-\(UUID().uuidString)", displayName: "Live test")
        try await RunnerInviteEnrollment.enroll(hostPublicKey: hostKey, enrollmentUsername: token.username,
                                                clientKey: clientKey, endpoint: invite.endpoint)
        let connection = DirectSSHHostConnection(clientKey: clientKey, expectedHostFingerprint: RemoteIdentityFingerprint(of: hostKey))
        do {
            try await connection.connect(tailcat: invite.endpoint)
            let team = try await connection.makeTeamClient(handler: { $0 }, onClose: {})
            defer { team.close() }
            try await team.open()
            let response = try JSONDecoder().decode(RemoteTeamResponse.self,
                from: try await team.send(JSONEncoder().encode(RemoteTeamRequest.list)))
            guard case .members = response else { throw HostRuntimeError.invalid("unexpected team response") }
        } catch { await connection.close(); throw error }
        await connection.close()
    }
}

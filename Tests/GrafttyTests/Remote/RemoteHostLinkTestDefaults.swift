import Foundation
import GrafttyProtocol
import GrafttyRemoteClient

struct RemoteHostLinkChannelUnavailable: Error {}

/// Mac-to-Mac test fakes conform to this so they implement only the channels
/// a test drives; each fake still declares its own `state`. The defaults hang off this test-only refinement rather than
/// `RemoteHostLink` itself: an async default there would outrank a production
/// actor's synchronous method at every `await` call site in this module.
protocol RemoteHostLinkFake: WebRTCHostLink {}

extension RemoteHostLinkFake {
    func makeWorktreeManagementDriver() async throws -> any WorktreeManagementChannelDriver {
        throw RemoteHostLinkChannelUnavailable()
    }

    func makeTeamClient(
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void
    ) async throws -> TeamChannelClient {
        throw RemoteHostLinkChannelUnavailable()
    }

    func forwardLocalPort(host: String, port: Int) async throws -> LocalPortForward {
        throw RemoteHostLinkChannelUnavailable()
    }

    func createOfferSDP() async throws -> String { "v=0\n" }
    func applyAnswerSDP(_ sdp: String) async throws {}
}

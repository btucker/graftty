import Testing
import WebRTC
@testable import GrafttyHostAgent
import GrafttyRemoteClient

@Suite("WebRTC non-trickle ICE gathering policy")
struct ICEGatheringPolicyTests {
    @Test("""
    @spec REMOTE-11.5: While Graftty uses non-trickle SDP signaling, the application shall configure both peers to gather ICE candidates once so offer and answer generation can finish when the initial candidates have been collected.
    """)
    func nonTricklePeersGatherOnce() {
        #expect(
            RemoteHostConnection.defaultConfig().continualGatheringPolicy
                == .gatherOnce
        )
        #expect(
            WebRTCHostAgent.defaultConfig().continualGatheringPolicy
                == .gatherOnce
        )
    }
}

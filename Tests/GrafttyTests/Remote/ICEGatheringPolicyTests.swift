import Testing
import WebRTC
import GrafttyRemoteClient
import GrafttyTunnel

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
            WebRTCPeerSupport.defaultConfig().continualGatheringPolicy
                == .gatherOnce
        )
    }

    @Test("""
    @spec REMOTE-11.30: The application shall configure both peers to tolerate high-latency links: a candidate pair shall stop counting as receiving only after ten seconds without inbound traffic, become unwritable (ICE disconnected) only after ten seconds without check responses, and time out (ICE failed) only after thirty seconds without check responses.
    """)
    func peersTolerateHighLatencyLinks() {
        for config in [RemoteHostConnection.defaultConfig(), WebRTCPeerSupport.defaultConfig()] {
            #expect(config.iceConnectionReceivingTimeout == 10_000)
            #expect(config.iceUnwritableTimeout?.intValue == 10_000)
            #expect(config.iceInactiveTimeout?.intValue == 30_000)
        }
    }
}

import Foundation
import Testing
@testable import GrafttyRemoteClient

@Suite("@spec REMOTE-11.29: The client shall allow thirty seconds for a signaling request to complete, an SSH child channel to open, and a panes-state initial snapshot to arrive, so a link with multi-second round trips is not torn down as stalled.")
struct RemoteLinkDeadlinesTests {
    @Test func signalingRequestsGetThirtySeconds() {
        #expect(RemoteLinkDeadlines.signalingRequest == 30)
    }

    @Test func childChannelOpensGetThirtySeconds() {
        #expect(RemoteLinkDeadlines.childChannelOpen == .seconds(30))
    }

    @Test func firstSnapshotsGetThirtySeconds() {
        #expect(RemoteLinkDeadlines.firstSnapshot == .seconds(30))
    }
}

import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite
struct AutomaticDisplayOwnershipTests {
    enum PreviousLeader: CaseIterable { case absent, detached, hidden }

    @Test("@spec OWN-1.7: When a visible interactive client attaches and no eligible attached leader exists, the application shall make that client the leader, preserve the retained grid until its viewport is confirmed, and notify ownership observers.",
          arguments: [DisplayClientKind.mac, .ios, .web], PreviousLeader.allCases)
    func attachmentAcquiresVacantLeadership(kind: DisplayClientKind, previous: PreviousLeader) throws {
        let store = SessionDisplayOwnershipStore()
        let retainedGrid = try DisplayGrid(cols: 120, rows: 40)
        let localGrid = try DisplayGrid(cols: 80, rows: 24)
        var previousEpoch: UInt64 = 0
        if previous != .absent {
            _ = store.attachClient(sessionName: "session", clientID: .init("old"), kind: .mac,
                                   role: .interactive, visible: true, grid: retainedGrid)
            previousEpoch = store.claimOwner(sessionName: "session", clientID: .init("old"),
                kind: .mac, grid: retainedGrid).snapshot.epoch
            if previous == .detached {
                _ = store.detachClient(sessionName: "session", clientID: .init("old"))
            } else {
                _ = store.attachClient(sessionName: "session", clientID: .init("old"), kind: .mac,
                                       role: .interactive, visible: false, grid: retainedGrid)
            }
        }
        final class Observed: @unchecked Sendable { var snapshots: [DisplayOwnershipSnapshot] = [] }
        let observed = Observed()
        let token = store.addObserver { observed.snapshots.append($0) }
        defer { token.cancel() }
        let result = store.attachClient(sessionName: "session", clientID: .init("new"), kind: kind,
                                       role: .interactive, visible: true, grid: localGrid)
        #expect(result.ownerClientID == .init("new"))
        #expect(result.ownerKind == kind)
        #expect(result.epoch > previousEpoch)
        #expect(result.grid == (previous == .absent ? localGrid : retainedGrid))
        #expect(store.isAttachedOwner(sessionName: "session", clientID: .init("new")))
        #expect(observed.snapshots == [result])
    }

    @Test(arguments: [false, true])
    func activeLeaderKeepsControl(detachFormerLeader: Bool) throws {
        let store = SessionDisplayOwnershipStore()
        let grid = DisplayGrid.daemonFallback
        _ = store.attachClient(sessionName: "session", clientID: .init("old"), kind: .mac,
                               role: .interactive, visible: true, grid: grid)
        _ = store.claimOwner(sessionName: "session", clientID: .init("old"), kind: .mac, grid: grid)
        if detachFormerLeader { _ = store.detachClient(sessionName: "session", clientID: .init("old")) }
        _ = store.attachClient(sessionName: "session", clientID: .init("phone"), kind: .ios,
                               role: .interactive, visible: true, grid: grid)
        let leader = store.claimOwner(sessionName: "session", clientID: .init("phone"), kind: .ios, grid: grid).snapshot
        let reattached = store.attachClient(sessionName: "session", clientID: .init("old"), kind: .mac,
                                           role: .interactive, visible: true, grid: grid)
        #expect(reattached.ownerClientID == leader.ownerClientID)
        #expect(reattached.epoch == leader.epoch)
    }
}

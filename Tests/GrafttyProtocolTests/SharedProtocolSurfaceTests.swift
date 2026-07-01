import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct SharedProtocolSurfaceTests {

    @Test("""
    @spec IOS-1.3: Wire-format types shared between `GrafttyMobile` and the `GrafttyKit` web server — `SessionInfo`, `WebControlEnvelope` — shall live in a shared library target `GrafttyProtocol`, imported by both targets. This ensures a breaking JSON-shape change is a compile-time error on both sides.
    """)
    func sharedWireTypesAreAvailableFromProtocolTarget() throws {
        let session = SessionInfo(
            name: "graftty-abcd1234",
            worktreePath: "/repo/.worktrees/feature",
            repoDisplayName: "repo",
            worktreeDisplayName: "feature"
        )
        let sessionData = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(SessionInfo.self, from: sessionData) == session)

        let envelope = try WebControlEnvelope.parse(
            Data(#"{"type":"ownerResize","clientID":"web-1","epoch":1,"cols":80,"rows":24}"#.utf8)
        )
        #expect(envelope == .ownerResize(
            clientID: DisplayClientID("web-1"),
            epoch: 1,
            cols: 80,
            rows: 24
        ))

        let snapshot = try DisplayOwnershipSnapshot(
            sessionName: "graftty-abcd1234",
            ownerClientID: DisplayClientID("web-1"),
            ownerKind: .web,
            grid: try DisplayGrid(cols: 80, rows: 24),
            epoch: 1
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(DisplayOwnershipSnapshot.self, from: snapshotData) == snapshot)
    }
}

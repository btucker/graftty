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
            Data(#"{"type":"resize","cols":80,"rows":24}"#.utf8)
        )
        #expect(envelope == .resize(cols: 80, rows: 24))
    }
}

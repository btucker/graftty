import Foundation
import Testing
@testable import GrafttyKit

@Suite("graftty team register — pane resolution")
struct TeamRegisterCLITests {
    @Test("@spec TEAM-IDLE-2.9: When ZMX_SESSION is set, the recorded paneSessionName equals it.")
    func paneSessionNameFromZmxSession() {
        let env = ["ZMX_SESSION": "graftty-abc12345"]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == "graftty-abc12345")
    }

    @Test("@spec TEAM-IDLE-2.10: When ZMX_SESSION is unset, the recorded paneSessionName is nil.")
    func paneSessionNameNilWhenUnset() {
        let env: [String: String] = [:]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("Empty ZMX_SESSION is treated as unset.")
    func paneSessionNameNilWhenEmpty() {
        let env = ["ZMX_SESSION": ""]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }
}

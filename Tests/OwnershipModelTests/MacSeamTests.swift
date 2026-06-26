import Testing
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@Suite("Mac seam S6/S7")
struct MacSeamTests {
    @Test func followerMacNeverResizesPTYAndConvergesToOwnerGrid() throws {
        var world = MultiTransportWorld(session: "main")
        let mac = DisplayClientID("mac-1"); let web = DisplayClientID("web-1")
        world.attachMac(id: mac, grid: try DisplayGrid(cols: 80, rows: 24))      // mac becomes owner
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30)) // web takes over; mac is follower
        world.quiesce()
        #expect(world.oracle.violations.contains { if case .s6NonOwnerResizedPTY = $0 { return true }; return false } == false)
        #expect(world.macPTYLastSize == nil || world.macPTYLastSize! == (100, 30)) // converges to owner grid (L1)
    }
}

import Testing
import Foundation
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

/// Randomized S6/S7 sweep: under random interleavings of web takeover/release
/// and Mac surface-resize/write attempts, the real `HostManagedZmxBackend`
/// ownership gate must never let a follower touch the PTY.  Unlike the
/// fault-injection teeth test, every Mac action here goes through the production
/// `receiveResize`/`write` seams so `authorizeOwnerResizeLocked`/`writeAllowed`
/// are the deciders.
@Suite("Mac gate randomized sweep")
struct MacModelCheckTests {
    /// Run one randomized Mac-gate scenario.  Returns the accumulated violations
    /// and how many Mac PTY actions were driven while a web client owned the
    /// display (the follower-block path the sweep must exercise non-vacuously).
    private func runMacGateScenario(seed: UInt64) throws -> (violations: [Violation], followerDrives: Int) {
        var rng = DeterministicRNG(seed: seed)
        var world = MultiTransportWorld(session: "mac-\(seed)")
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")

        try world.attachMac(id: mac, grid: DisplayGrid(cols: 80, rows: 24))
        world.driveMacSurfaceResize(cols: 80, rows: 24)  // settle layout as owner

        var webOwns = false
        var followerDrives = 0
        for _ in 0..<24 {
            switch rng.int(in: 0..<4) {
            case 0:
                world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
                world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30))
                webOwns = true
            case 1:
                if webOwns {
                    world.releaseOwner(ownerProtocolID: web)
                    webOwns = false
                }
            case 2:
                world.driveMacSurfaceResize(cols: UInt16(80 + rng.int(in: 0..<120)), rows: 30)
                if webOwns { followerDrives += 1 }
            default:
                world.driveMacWrite(Data("x".utf8))
                if webOwns { followerDrives += 1 }
            }
        }
        return (world.oracle.violations, followerDrives)
    }

    @Test(arguments: Array<UInt64>(1...80))
    func followerGateHoldsUnderInterleaving(seed: UInt64) throws {
        let (violations, _) = try runMacGateScenario(seed: seed)
        let hasS6 = violations.contains { if case .s6NonOwnerResizedPTY = $0 { return true }; return false }
        let hasS7 = violations.contains { if case .s7NonOwnerInput = $0 { return true }; return false }
        #expect(!hasS6, "seed \(seed): a follower resized the PTY through the real gate")
        #expect(!hasS7, "seed \(seed): a follower wrote to the PTY through the real gate")
    }

    /// Non-vacuity: at least one seed must drive a Mac PTY action while a web
    /// client owns the display.  If this is always zero the sweep never exercises
    /// the follower-block path and the S6/S7 corpus check is vacuous.
    @Test func macFollowerDriveIsNonVacuous() throws {
        var total = 0
        for seed: UInt64 in 1...80 {
            total += try runMacGateScenario(seed: seed).followerDrives
            if total > 0 { break }
        }
        #expect(total > 0, "no seed drove a Mac PTY action while a web client owned — S6/S7 sweep is vacuous")
    }
}

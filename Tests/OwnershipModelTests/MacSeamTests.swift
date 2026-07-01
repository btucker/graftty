import Testing
import Foundation
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@Suite("Mac seam S6/S7")
struct MacSeamTests {

    /// Non-vacuous L1 PTY convergence proof (owner phase) and follower
    /// non-chase proof (follower phase).
    ///
    /// (a) While the Mac is the owner, quiescing must flush the PTY to its
    ///     owned grid (80×24) — proves the real backend DID resize, not nil.
    /// (b) After the web takes control at 100×30, the Mac becomes a follower.
    ///     Its PTY must NOT be resized to 100×30 — no S6 violation, and
    ///     `macPTYLastSize` stays at 80×24 (unchanged from the owner phase).
    @Test func macOwnerConvergesAndFollowerDoesNotChase() throws {
        var world = MultiTransportWorld(session: "main")
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")

        // ── (a) Owner phase ──────────────────────────────────────────────
        // Mac is the first visible interactive client so it auto-claims ownership
        // in the store. quiesce() calls markLayoutSettled(), which flushes the
        // live grid (80×24) to the PTY through the ownership gate.
        try world.attachMac(id: mac, grid: DisplayGrid(cols: 80, rows: 24))
        world.quiesce()

        // Non-vacuous: the backend must have flushed its PTY to the owned grid.
        // If macPTYLastSize is nil here the owner backend never resized — a real
        // finding; stop and report rather than forcing the assertion.
        let ownerSize = try #require(world.macPTYLastSize,
            "owner PTY must converge to its owned grid after quiesce (L1 PTY clause)")
        #expect(ownerSize == (80, 24), "owner PTY must equal the owned grid")

        // ── (b) Follower phase ───────────────────────────────────────────
        // Web takes control at 100×30; Mac is now a follower.
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30))
        world.quiesce()

        // The Mac's PTY must NOT have chased the new owner's 100×30 grid.
        // macPTYLastSize reflects the cumulative last resize; a chase would
        // update it to (100, 30).
        let followerSize = try #require(world.macPTYLastSize,
            "macPTYLastSize must remain non-nil after follower quiesce")
        #expect(followerSize == ownerSize,
            "follower PTY must not chase the new owner's grid (S6 absent)")

        // No S6 or S7 violations must have been recorded.
        let hasS6 = world.oracle.violations.contains {
            if case .s6NonOwnerResizedPTY = $0 { return true }; return false
        }
        let hasS7 = world.oracle.violations.contains {
            if case .s7NonOwnerInput = $0 { return true }; return false
        }
        #expect(!hasS6, "no S6 violations expected while follower quiesces without fault injection")
        #expect(!hasS7, "no S7 violations expected while follower quiesces without fault injection")
    }

    /// S6/S7 through the REAL ownership gate (not the fault-injection bypass).
    ///
    /// The existing convergence test only relies on `quiesce()`, which never
    /// *attempts* a resize while the Mac is a follower — so its follower-phase
    /// assertion passes because nothing tried, not because the gate blocked.
    /// This test actively drives the production `receiveResize`/`write` seams:
    ///
    /// (a) While the Mac owns, driving a surface resize reaches the PTY — proving
    ///     the drive path is live, so the follower block below is meaningful.
    /// (b) After the web takes over, driving the SAME seams must be blocked by
    ///     `authorizeOwnerResizeLocked`/`writeAllowed` — the PTY is untouched and
    ///     no S6/S7 fires.  A gate regression would let the resize/write through
    ///     and trip the oracle.
    @Test func macFollowerGateBlocksRealSurfaceResizeAndWrite() throws {
        var world = MultiTransportWorld(session: "main")
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")

        try world.attachMac(id: mac, grid: DisplayGrid(cols: 80, rows: 24))

        // (a) Owner phase: a real surface resize reaches the PTY through the gate.
        world.driveMacSurfaceResize(cols: 90, rows: 24)
        let ownerSize = try #require(world.macPTYLastSize,
            "owner surface resize must reach the PTY through the real gate")
        #expect(ownerSize == (90, 24))

        // Web takes control → Mac is now a follower.
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30))

        // (b) Follower phase: the same real seams must be blocked by the gate.
        world.driveMacSurfaceResize(cols: 140, rows: 50)
        world.driveMacWrite(Data("blocked".utf8))

        let followerSize = try #require(world.macPTYLastSize,
            "macPTYLastSize must remain non-nil after the follower drive")
        #expect(followerSize == ownerSize,
            "follower surface resize must be blocked by the real gate (PTY size unchanged)")
        let hasS6 = world.oracle.violations.contains {
            if case .s6NonOwnerResizedPTY = $0 { return true }; return false
        }
        let hasS7 = world.oracle.violations.contains {
            if case .s7NonOwnerInput = $0 { return true }; return false
        }
        #expect(!hasS6, "real gate must block the follower PTY resize (no S6)")
        #expect(!hasS7, "real gate must block the follower PTY write (no S7)")
    }

    /// S6/S7 oracle "teeth" test: prove the oracle CAN detect violations.
    ///
    /// With the Mac in follower state, `injectMacPTYResize` and
    /// `injectMacPTYWrite` simulate a buggy backend that bypassed its
    /// ownership gate and called the PTY session directly.  The oracle
    /// hooks on `FakeZmxSession` must fire and record both violations.
    @Test func s6AndS7OracleFireOnFaultInjection() throws {
        var world = MultiTransportWorld(session: "teeth")
        let mac = DisplayClientID("mac-1")
        let web = DisplayClientID("web-1")

        // Bring Mac up as owner, then let web take over so Mac is a follower.
        try world.attachMac(id: mac, grid: DisplayGrid(cols: 80, rows: 24))
        world.webHandle(.hello(clientID: web, kind: .web, role: .interactive, visible: true, cols: 100, rows: 30))
        world.webHandle(.takeControl(clientID: web, kind: .web, cols: 100, rows: 30))
        // (No quiesce here — markLayoutSettled not yet called, so the oracle
        // baseline is clean.)

        // Fault-inject: bypass the ownership gate and call the PTY session directly.
        // Each inject drains macViolations into oracle.violations immediately.
        world.injectMacPTYResize(cols: 100, rows: 30)
        world.injectMacPTYWrite(Data("x".utf8))

        // S6 must have fired because the Mac resized its PTY while a follower.
        #expect(
            world.oracle.violations.contains {
                if case .s6NonOwnerResizedPTY(let id) = $0 { return id == mac }
                return false
            },
            "S6 oracle must fire when a follower's PTY is resized by a buggy backend"
        )

        // S7 must have fired because the Mac wrote to its PTY while a follower.
        #expect(
            world.oracle.violations.contains {
                if case .s7NonOwnerInput(let id) = $0 { return id == mac }
                return false
            },
            "S7 oracle must fire when a follower's PTY receives input from a buggy backend"
        )
    }
}

import Testing
import Foundation
@testable import EspalierKit

@Suite("SurfacePWDPoller — dedup + change detection")
@MainActor
struct SurfacePWDPollerTests {

    // The poller backs PWD-1.3: a timer-driven fallback that reads
    // each tracked pane's inner-shell cwd via PID and fires the same
    // onPWDChange callback that OSC 7 does. Unit tests drive the
    // polling tick explicitly via `pollOnce()`; the live timer is
    // the caller's problem.

    @Test func firesOnFirstObservedCwd() throws {
        let id = TerminalID(id: UUID())
        var events: [(TerminalID, String)] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in "/tmp/a" },
            onChange: { terminalID, pwd in events.append((terminalID, pwd)) }
        )
        poller.track(id)

        poller.pollOnce()

        #expect(events.count == 1)
        #expect(events[0].0 == id)
        #expect(events[0].1 == "/tmp/a")
    }

    @Test func doesNotFireWhenCwdUnchanged() throws {
        let id = TerminalID(id: UUID())
        var events: [(TerminalID, String)] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in "/tmp/a" },
            onChange: { terminalID, pwd in events.append((terminalID, pwd)) }
        )
        poller.track(id)

        poller.pollOnce()
        poller.pollOnce()
        poller.pollOnce()

        // One change event for the first-observed cwd, none for the
        // two subsequent no-op ticks.
        #expect(events.count == 1)
    }

    @Test func firesWhenCwdChanges() throws {
        let id = TerminalID(id: UUID())
        var events: [(TerminalID, String)] = []
        var currentCwd = "/tmp/a"
        let poller = SurfacePWDPoller(
            resolve: { _ in currentCwd },
            onChange: { terminalID, pwd in events.append((terminalID, pwd)) }
        )
        poller.track(id)

        poller.pollOnce()
        currentCwd = "/tmp/b"
        poller.pollOnce()
        poller.pollOnce() // no-op at /tmp/b
        currentCwd = "/tmp/c"
        poller.pollOnce()

        #expect(events.map(\.1) == ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    @Test func skipsUntrackedTerminals() throws {
        let trackedID = TerminalID(id: UUID())
        var resolverCalls: [TerminalID] = []
        var events: [TerminalID] = []
        let poller = SurfacePWDPoller(
            resolve: { id in resolverCalls.append(id); return "/tmp/a" },
            onChange: { terminalID, _ in events.append(terminalID) }
        )
        poller.track(trackedID)

        poller.pollOnce()

        // Resolver should only be asked about ids that were tracked —
        // a stricter check than "events == [trackedID]" because it
        // catches a bug where the poller asks the resolver about every
        // id it has ever seen.
        #expect(resolverCalls == [trackedID])
        #expect(events == [trackedID])
    }

    @Test func untrackClearsMemorySoReaddFiresAgain() throws {
        let id = TerminalID(id: UUID())
        var events: [String] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in "/tmp/a" },
            onChange: { _, pwd in events.append(pwd) }
        )
        poller.track(id)
        poller.pollOnce()             // fires
        poller.untrack(id)
        poller.track(id)              // fresh start — memory was cleared
        poller.pollOnce()             // fires again

        #expect(events == ["/tmp/a", "/tmp/a"])
    }

    @Test func seedSuppressesFirstEventWhenValueUnchanged() throws {
        // Seeding is how TerminalManager hands the poller the cwd it
        // already knows (e.g., the worktree path used to spawn the
        // pane, or a fresh OSC 7 event). Without seeding, the first
        // poll would re-fire the already-known cwd as if it were new.
        let id = TerminalID(id: UUID())
        var events: [String] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in "/tmp/a" },
            onChange: { _, pwd in events.append(pwd) }
        )
        poller.track(id)
        poller.seed(id, pwd: "/tmp/a")
        poller.pollOnce()

        #expect(events.isEmpty)
    }

    @Test func seedUpdatesMemoryWithoutFiring() throws {
        let id = TerminalID(id: UUID())
        var events: [String] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in "/tmp/b" },
            onChange: { _, pwd in events.append(pwd) }
        )
        poller.track(id)
        poller.pollOnce()             // event for "/tmp/b"
        poller.seed(id, pwd: "/tmp/c") // OSC 7 arrived with /tmp/c
        poller.pollOnce()             // resolver still says /tmp/b → fires again

        #expect(events == ["/tmp/b", "/tmp/b"])
    }

    @Test func skipsIDsWithNilResolverResult() throws {
        // Log file missing, PID gone, kernel says nope — all surface
        // as resolver returning nil. Poller should not treat that
        // as "cwd changed to nil"; it should simply skip this tick.
        let id = TerminalID(id: UUID())
        var events: [String] = []
        let poller = SurfacePWDPoller(
            resolve: { _ in nil },
            onChange: { _, pwd in events.append(pwd) }
        )
        poller.track(id)
        poller.pollOnce()
        poller.pollOnce()

        #expect(events.isEmpty)
    }
}

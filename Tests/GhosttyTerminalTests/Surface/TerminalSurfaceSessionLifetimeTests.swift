@testable import GhosttyTerminal
import Testing

/// Ghostty's IO thread calls an in-memory session as unretained userdata
/// until the surface is freed, so teardown must keep the session alive past
/// `ghostty_surface_free` even when the coordinator holds its last reference.
@Suite("TerminalSurfaceSessionLifetime", .serialized)
struct TerminalSurfaceSessionLifetimeTests {
    @Test
    @MainActor
    func `a session swapped out while hidden outlives its surface`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let probe = DetachProbe()
        coordinator.delegate = probe

        weak var weakSession: InMemoryTerminalSession?
        do {
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            weakSession = session
            coordinator.configuration.backend = .inMemory(session)
        }
        #expect(coordinator.surface != nil)
        #expect(weakSession != nil)

        coordinator.viewSize = { (0, 0) }
        coordinator.configuration.backend = .inMemory(harness.session)
        #expect(coordinator.testHooks_pendingRebuild)
        #expect(weakSession != nil)

        probe.watched = weakSession
        probe.isArmed = true
        coordinator.viewSize = { (800, 500) }
        coordinator.synchronizeMetrics()

        #expect(probe.sessionAliveAtDetach == true)
        #expect(coordinator.surface != nil)
        #expect(weakSession == nil)
    }
}

@MainActor
private final class DetachProbe: TerminalSurfaceLifecycleDelegate {
    weak var watched: InMemoryTerminalSession?
    var isArmed = false
    var sessionAliveAtDetach: Bool?

    func terminalDidAttachSurface(_: TerminalSurface) {}

    func terminalDidDetachSurface() {
        guard isArmed else { return }
        isArmed = false
        sessionAliveAtDetach = watched != nil
    }
}

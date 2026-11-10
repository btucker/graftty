import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalRenderPaceTests {
    @Test("Reduced rendering keeps a trailing dirty frame without another request")
    func reducedRenderingPreservesTrailingFrame() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        let original = try #require(core.surface)
        var frames = 0
        core.onPostRender = { frames += 1 }
        core.renderPace = .reduced(interval: 1)
        core.tick(at: 10)
        for timestamp in [10.1, 10.2, 10.3] {
            core.requestImmediateTick()
            core.tick(at: timestamp)
        }
        #expect(frames == 1)
        // No new request: the previous dirty frame must still be owed.
        core.tick(at: 11)
        #expect(frames == 2)
        #expect(core.surface === original)
    }

    @Test("Promoting render pace immediately displays pending output")
    func promotionDisplaysPendingFrame() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        var frames = 0
        core.onPostRender = { frames += 1 }
        core.renderPace = .reduced(interval: 60)
        core.tick(at: 10)
        core.requestImmediateTick()
        core.tick(at: 10.1)
        #expect(frames == 1)
        core.renderPace = .full
        core.tick(at: 10.2)
        #expect(frames == 2)
    }

    @Test("Resizing bypasses a long reduced render interval")
    func resizeDisplaysImmediately() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        var frames = 0
        core.onPostRender = { frames += 1 }
        core.renderPace = .reduced(interval: 60)
        core.tick(at: 10)
        core.viewSize = { (900, 600) }
        core.fitToSize()
        core.tick(at: 10.1)
        #expect(frames == 2)
        #expect(core.syncedViewSize?.width == 900)
    }

    @Test("Reduced rendering leaves the native mailbox pump responsive")
    func reducedRenderingDoesNotBlockMailbox() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        let delegate = RenderPaceTitleDelegate()
        core.delegate = delegate
        core.renderPace = .reduced(interval: 60)
        core.tick(at: 10)
        harness.receive(String(repeating: "\u{1b}]2;mailbox\u{7}", count: 1024))
        core.controller?.handleWakeup()
        #expect(delegate.titles > 0)
        #expect(harness.session.pendingOutputByteCount == 0)
    }
}

@MainActor
private final class RenderPaceTitleDelegate: TerminalSurfaceTitleDelegate {
    var titles = 0
    func terminalDidChangeTitle(_ title: String) { titles += 1 }
}

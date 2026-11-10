import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalRetirementLifecycleTests {
    @Test("A configuration change while detached preserves the renderer until reattachment")
    func detachedConfigurationDefersRebuild() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        let original = try #require(core.surface)
        core.isAttached = { false }
        core.configuration.fontSize = 18
        #expect(core.surface === original)
        #expect(core.testHooks_pendingRebuild)
        core.isAttached = { true }
        core.synchronizeMetrics()
        #expect(core.surface != nil)
        #expect(core.surface !== original)
        #expect(!core.testHooks_pendingRebuild)
    }

    @Test("A controller change with zero bounds preserves the old owning controller until rebuild")
    func zeroSizeControllerChangeDefersRebuild() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let core = harness.coordinator
        let original = try #require(core.surface)
        let originalController = try #require(core.controller)
        let replacement = TerminalController()
        core.viewSize = { (0, 0) }
        core.controller = replacement
        #expect(core.surface === original)
        #expect(originalController.retainedBridgeCount == 1)
        #expect(replacement.retainedBridgeCount == 0)
        core.viewSize = { (800, 500) }
        core.synchronizeMetrics()
        #expect(core.surface != nil)
        #expect(core.surface !== original)
        #expect(originalController.retainedBridgeCount == 0)
        #expect(replacement.retainedBridgeCount == 1)
    }
}

@testable import GhosttyTerminal
import Testing

/// `ghostty_app_update_config` already reaches every surface the app owns;
/// a config change must land on each surface once, not once more per
/// surface on top of that.
@Suite("TerminalConfigApply", .serialized)
struct TerminalConfigApplyTests {
    @Test
    @MainActor
    func `a config change reaches each surface once`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let coordinator = harness.coordinator
        let controller = coordinator.controller
        #expect(coordinator.surface != nil)

        var configChanges = 0
        coordinator.bridge.onRenderRequest = { configChanges += 1 }
        let overrides = TerminalConfiguration { $0.withFontSize(17) }
        let applied = controller?.setTerminalConfiguration(overrides)

        #expect(applied == true)
        #expect(configChanges == 1)
    }
}

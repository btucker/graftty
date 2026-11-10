import AppKit
import Combine
@testable import GhosttyTerminal
import Testing

/// The platform view hears appearance changes from window attach and
/// effective-appearance callbacks, which SwiftUI can run inside its update
/// pass; adopting the scheme from there must not publish synchronously.
@Suite("TerminalColorSchemeAdoption", .serialized)
struct TerminalColorSchemeAdoptionTests {
    @Test
    @MainActor
    func `the view adopts its appearance on the next turn`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let state = TerminalViewState()
        let view = AppTerminalView(frame: .zero)
        view.appearance = NSAppearance(named: .darkAqua)
        view.delegate = state
        view.controller = state.controller
        #expect(state.controller.effectiveColorScheme == .light)

        var published = 0
        let sink = state.objectWillChange.sink { published += 1 }
        defer { sink.cancel() }

        view.updateColorScheme()
        #expect(published == 0)
        #expect(state.controller.effectiveColorScheme == .light)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(published > 0)
        #expect(state.controller.effectiveColorScheme == .dark)
    }
}

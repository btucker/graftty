import AppKit
import Testing
@testable import Graftty

@MainActor
struct WorkspaceWindowTests {
    @Test("@spec LAYOUT-1.15: When the user opens another main window on macOS, the application shall open a separate window even when macOS prefers tabbing.")
    func mainWindowsDisallowTabbing() {
        let tracker = WindowFrameTracker.Coordinator(
            initialFrame: nil, onFrameChange: { _ in }, debounceInterval: 0
        )
        let window = NSWindow()
        window.tabbingMode = .preferred

        tracker.attach(to: window)

        #expect(window.tabbingMode == .disallowed)
    }

    @Test("@spec LAYOUT-1.16: While several main windows are open on macOS, the application shall keep each window's worktree selection independent and restore the saved selection only when opening the first main window.")
    func selectionsAreWindowLocal() {
        let windows = WorkspaceWindows()
        let first = WorkspaceWindowSelection()
        let second = WorkspaceWindowSelection()
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let original = UUID()
        let other = UUID()

        #expect(windows.attach(first, to: firstWindow))
        #expect(windows.select(original, in: first))
        #expect(!windows.attach(second, to: secondWindow))
        #expect(second.worktreeID == nil)
        #expect(windows.select(other, in: second))
        windows.makeActive(second)

        #expect(first.worktreeID == original)
        #expect(second.worktreeID == other)
        #expect(windows.active === second)
    }

    @Test("@spec LAYOUT-1.17: When the user selects a local worktree already displayed in another main window, the application shall bring that window forward and preserve the current worktree in each window.")
    func existingWindowKeepsOwnershipUntilItCloses() {
        let windows = WorkspaceWindows()
        let first = WorkspaceWindowSelection()
        let second = WorkspaceWindowSelection()
        let firstWindow = WindowSpy()
        let secondWindow = NSWindow()
        let original = UUID()
        let other = UUID()
        firstWindow.isReleasedWhenClosed = false
        let tracker = WindowFrameTracker.Coordinator(
            initialFrame: nil, onFrameChange: { _ in }, debounceInterval: 0,
            onAttach: { windows.attach(first, to: $0) },
            onDetach: { windows.detach(first, from: $0) }
        )
        tracker.attach(to: firstWindow)
        windows.attach(second, to: secondWindow)
        windows.select(original, in: first)
        windows.select(other, in: second)

        #expect(!windows.select(original, in: second))
        #expect(firstWindow.wasBroughtForward)
        #expect(first.worktreeID == original)
        #expect(second.worktreeID == other)

        firstWindow.close()
        #expect(windows.select(original, in: second))
        #expect(windows.windowShowing(original) === second)
    }
}

private final class WindowSpy: NSWindow {
    var wasBroughtForward = false

    override func makeKeyAndOrderFront(_ sender: Any?) {
        wasBroughtForward = true
    }
}

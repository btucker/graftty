import AppKit
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@Suite("Project worktree column empty space")
@MainActor
struct ProjectWorktreeColumnTests {
    @Test("@spec LAYOUT-2.69: When the user double-clicks empty space after the last worktree in the project column, the application shall open Add Worktree for the selected editable project without changing a worktree row's click behavior.")
    func doubleClickOpensAddWorktree() throws {
        var openings = 0
        let view = ProjectWorktreeEmptySpaceView()
        view.onDoubleClick = { openings += 1 }

        view.mouseDown(with: try mouseDown(clickCount: 1))
        #expect(openings == 0)

        view.mouseDown(with: try mouseDown(clickCount: 2))
        #expect(openings == 1)
    }

    @Test func emptySpaceFillsAreaBelowRows() async throws {
        let hosting = NSHostingView(rootView: ProjectWorktreeColumn(onDoubleClickEmptySpace: {}) {
            Text("Worktree").frame(height: 44)
        })
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let blank = try #require(findEmptySpace(in: hosting))
        #expect(blank.frame.height > 100)
    }

    private func findEmptySpace(in view: NSView) -> ProjectWorktreeEmptySpaceView? {
        if let emptySpace = view as? ProjectWorktreeEmptySpaceView { return emptySpace }
        return view.subviews.lazy.compactMap(findEmptySpace).first
    }

    private func mouseDown(clickCount: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}

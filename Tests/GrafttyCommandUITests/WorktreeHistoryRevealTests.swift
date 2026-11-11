#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeHistoryRevealTests {
    private let start = Date(timeIntervalSince1970: 1_792_411_200)

    @Test("@spec CONTEXT-31: When the user clicks a human input line in worktree history on Mac or mobile, the application shall scroll the agent terminal to that message, and if the message is not in the terminal's loaded scrollback, show a brief Not in terminal history note beneath the line instead of an alert.")
    func clickingInputRevealsOrNotesMissing() async throws {
        var history = WorktreeHistory()
        history.record(.init(text: "Please fix the sidebar layout.", at: start))
        var found = false
        var revealed: [String] = []
        let timeline = WorktreeTimeline(history: history, brief: nil)
        let host = try Host(WorktreeHistoryContent(timeline: timeline, secondary: .secondary,
            revealInTerminal: { revealed.append($0); return found }))
        defer { host.close() }
        let collapsed = host.height
        // The input's one line sits under its day label, right of the You label.
        try await host.click(x: 160, fromTop: 54)
        #expect(revealed == [timeline.events[0].id])
        #expect(host.height > collapsed + 8, "A message missing from scrollback must show a note")
        found = true
        try await host.click(x: 160, fromTop: 54)
        #expect(revealed.count == 2)
        #expect(abs(host.height - collapsed) < 1, "A found message must clear the note")
    }

    @Test("@spec CONTEXT-32: While worktree history shows a peer message on Mac or mobile, the application shall keep tapping the message to expand its full text, and offer Show in terminal beneath the expanded text and in the message's context menu to scroll the agent terminal to it.")
    func peerMessageExpandsThenReveals() async throws {
        var history = WorktreeHistory()
        history.record(.init(text: "<graftty-peer-message agent=\"/repo/layout#claude\">Checked the layout.</graftty-peer-message>", at: start))
        var revealed: [String] = []
        let timeline = WorktreeTimeline(history: history, brief: nil)
        let host = try Host(WorktreeHistoryContent(timeline: timeline, secondary: .secondary,
            gists: PeerMessageGistProvider { _ in nil }, revealInTerminal: { revealed.append($0); return true }))
        defer { host.close() }
        let collapsed = host.height
        // The message line follows the sender link on the row's first line.
        try await host.click(x: 220, fromTop: 54)
        #expect(revealed.isEmpty, "Tapping a peer message expands it without scrolling the terminal")
        #expect(host.height > collapsed + 30)
        // Show in terminal is the last control under the expanded text.
        try await host.click(x: 150, fromBottom: 36)
        #expect(revealed == [timeline.events[0].id])
    }

    @MainActor
    private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow

        init(_ content: some View) throws {
            view = NSHostingView(rootView: AnyView(content.padding(20).frame(width: 320).fixedSize(horizontal: false, vertical: true)))
            window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: view.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
        }

        var height: Double { view.fittingSize.height }

        func click(x: Double, fromTop offset: Double) async throws {
            try await click(x: x, top: offset)
        }

        func click(x: Double, fromBottom offset: Double) async throws {
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            try await click(x: x, top: height - offset)
        }

        private func click(x: Double, top: Double) async throws {
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let point = view.convert(NSPoint(x: x, y: view.isFlipped ? top : view.bounds.height - top), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(60))
                view.layoutSubtreeIfNeeded()
            }
        }

        func close() { window.close() }
    }
}
#endif

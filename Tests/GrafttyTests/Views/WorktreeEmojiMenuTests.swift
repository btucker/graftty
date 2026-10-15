import AppKit
import Testing
@testable import Graftty

@Suite("Worktree emoji identity menu")
struct WorktreeEmojiMenuTests {
    @Test("@spec LAYOUT-2.96: When a user right-clicks a linked worktree's emoji identity, the application shall offer Change Emoji and, while an emoji is set, Clear Emoji there instead of in the worktree row menu.")
    @MainActor func identityMenuOffersChangeAndClear() {
        var changes = 0, clears = 0
        let withEmoji = WorktreeEmojiMenu.build(hasEmoji: true, onChange: { changes += 1 }, onClear: { clears += 1 })
        #expect(withEmoji.items.map(\.title) == ["Change Emoji…", "Clear Emoji"])
        for item in withEmoji.items { _ = item.target?.perform(item.action, with: item) }
        #expect(changes == 1 && clears == 1)
        let without = WorktreeEmojiMenu.build(hasEmoji: false, onChange: {}, onClear: {})
        #expect(without.items.map(\.title) == ["Choose Emoji…"])
    }

    @Test("@spec LAYOUT-2.99: When the native macOS emoji palette inserts text into the worktree identity capture, the application shall deliver only the first insertion and release the capture responder.")
    @MainActor func paletteCaptureDeliversFirstInsertion() {
        var picked: [String] = []
        let capture = WorktreeEmojiPaletteCapture(onPick: { picked.append($0) })
        capture.insertText(NSAttributedString(string: "🧪"), replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.insertText("🚀", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(picked == ["🧪"])
        #expect(capture.acceptsFirstResponder)
    }

    @Test("@spec LAYOUT-2.148: When Change Emoji is chosen from a worktree identity menu, the application shall open the native picker after menu tracking ends with the owning window key and its capture responder ready, including on repeated attempts.")
    @MainActor func paletteWaitsForMenuAndRestoresFocus() async throws {
        let window = EmojiPaletteTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 160),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let field = NSTextView(frame: NSRect(x: 30, y: 30, width: 100, height: 40))
        let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        content.addSubview(field)
        content.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var picked: [String] = []
        for _ in 0..<2 {
            window.resignKey()
            #expect(window.makeFirstResponder(field))
            var presentations = 0
            let previousKeyRequests = window.keyRequests
            var keyRequestsAtPresentation = 0
            var responderAtPresentation: NSResponder?
            WorktreeEmojiPaletteCapture.present(anchoredTo: anchor, showPalette: {
                presentations += 1
                keyRequestsAtPresentation = window.keyRequests
                responderAtPresentation = window.firstResponder
            }, onPick: { picked.append($0) })
            #expect(presentations == 0, "Wait for the menu action to return before opening the picker")
            try await Task.sleep(for: .milliseconds(100))
            #expect(presentations == 1)
            #expect(keyRequestsAtPresentation == previousKeyRequests + 1)
            #expect(responderAtPresentation is WorktreeEmojiPaletteCapture)
            let capture = try #require(window.firstResponder as? WorktreeEmojiPaletteCapture)
            #expect(capture.inputContext != nil)
            capture.insertText("🧪", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(capture.superview == nil)
            #expect(window.firstResponder === field)
        }
        #expect(picked == ["🧪", "🧪"])
    }

    @Test("A keystroke after the palette closes releases the capture without delivering a pick")
    @MainActor func keystrokeReleasesCapture() throws {
        var picked: [String] = []
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let capture = WorktreeEmojiPaletteCapture(onPick: { picked.append($0) })
        parent.addSubview(capture)
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        capture.keyDown(with: key)
        #expect(picked.isEmpty)
        #expect(capture.superview == nil)
    }
}

/// The test runner is not an active GUI application, so record the native
/// request to make the owner key instead of relying on application activation.
@MainActor
private final class EmojiPaletteTestWindow: NSWindow {
    var keyRequests = 0
    override func makeKeyAndOrderFront(_ sender: Any?) {
        keyRequests += 1
        super.makeKeyAndOrderFront(sender)
    }
}

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

import AppKit
import Testing
@testable import Graftty

@MainActor
struct SurfaceTextInputTests {
    @Test("@spec KEY-1.6: When macOS supplies provisional text to a terminal, the application shall expose an AppKit text input client that retains composition separately from terminal input.")
    func nativeTextInputClient() throws {
        _ = NSApplication.shared
        let view: NSView = SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let client = try #require(view as? any NSTextInputClient)
        #expect(!client.hasMarkedText())
        #expect(client.markedRange().location == NSNotFound)
        #expect(client.selectedRange() == NSRange(location: 0, length: 0))
    }
}

@MainActor
struct NativeDictationDeliveryTests {
    private let noReplacement = NSRange(location: NSNotFound, length: 0)

    @Test("Provisional revisions stay out of the terminal and expose UTF-16 ranges")
    func provisionalText() {
        let fixture = TextInputFixture()
        let view = fixture.view
        view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0), replacementRange: noReplacement)
        view.setMarkedText(NSAttributedString(string: "hi 🌍"), selectedRange: NSRange(location: 5, length: 0), replacementRange: noReplacement)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.preedits == ["hello", "hi 🌍"])
        #expect(view.markedRange() == NSRange(location: 0, length: 5))
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        var actual = NSRange()
        let substring = view.attributedSubstring(forProposedRange: NSRange(location: 4, length: 1), actualRange: &actual)
        #expect(substring?.string == "🌍")
        #expect(actual == NSRange(location: 3, length: 2))
        #expect(view.attributedSubstring(forProposedRange: noReplacement, actualRange: nil) == nil)
    }

    @Test("@spec KEY-1.7: When macOS commits text to the focused terminal, the application shall deliver it once as single-line text without appending Return or forwarding terminal control characters.")
    func committedText() {
        let fixture = TextInputFixture()
        fixture.view.setMarkedText("unfinished", selectedRange: .init(location: 10, length: 0), replacementRange: noReplacement)
        fixture.view.insertText(NSAttributedString(string: "café 🌍\r\nnext\u{2028}line\u{1B}\u{0}"), replacementRange: noReplacement)
        #expect(fixture.writes == ["café 🌍 next line"])
        #expect(fixture.preedits.last == "")
        #expect(!fixture.view.hasMarkedText())
        // A second identical commit is a new utterance, not a duplicate callback.
        fixture.view.insertText("again", replacementRange: noReplacement)
        fixture.view.insertText("again", replacementRange: noReplacement)
        #expect(fixture.writes.suffix(2) == ["again", "again"])
    }

    @Test("Unicode format characters in emoji and scripts survive insertion")
    func unicodeText() {
        let fixture = TextInputFixture()
        fixture.view.insertText("👩‍💻 می‌روم", replacementRange: noReplacement)
        #expect(fixture.writes == ["👩‍💻 می‌روم"])
    }

    @Test("Replacement ranges can edit only the provisional document")
    func replacementRanges() {
        let fixture = TextInputFixture()
        let view = fixture.view
        view.setMarkedText("helo", selectedRange: .init(location: 4, length: 0), replacementRange: noReplacement)
        view.setMarkedText("ll", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 2, length: 1))
        #expect(fixture.preedits.last == "hello")
        view.insertText("!", replacementRange: .init(location: 5, length: 0))
        #expect(fixture.writes == ["hello!"])
        view.insertText("replacement of committed text", replacementRange: .init(location: 0, length: 6))
        #expect(fixture.writes == ["hello!"])
    }

    @Test("@spec KEY-1.8: When a composing terminal loses focus, closes, or becomes read-only, the application shall discard provisional text and reject subsequent text callbacks while that pane is unavailable for input.")
    func invalidatedTarget() {
        let fixture = TextInputFixture()
        let view = fixture.view
        view.setMarkedText("discard", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        fixture.window.makeFirstResponder(nil)
        view.insertText("late", replacementRange: noReplacement)
        #expect(!view.hasMarkedText())
        #expect(fixture.writes.isEmpty)
        fixture.window.makeFirstResponder(view)
        view.setMarkedText("discard", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        view.isReadonly = true
        #expect(!view.hasMarkedText())
        view.insertText("blocked", replacementRange: noReplacement)
        view.isReadonly = false
        view.surface = nil
        view.insertText("closed", replacementRange: noReplacement)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Window deactivation cancels and rejects late callbacks until activation")
    func windowDeactivation() {
        let fixture = TextInputFixture()
        fixture.view.setMarkedText("discard", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        fixture.view.insertText("late", replacementRange: noReplacement)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.view.hasMarkedText())
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        fixture.view.insertText("new", replacementRange: noReplacement)
        #expect(fixture.writes == ["new"])
    }

    @Test("@spec OWN-2.6: When native text input commits to a follower terminal, the application shall acquire display ownership before delivering text and shall reject delivery if acquisition fails.")
    func displayOwnership() {
        let fixture = TextInputFixture()
        var transitions: [String] = []
        fixture.view.canTakeDisplayControlNotifier = { true }
        fixture.view.takeDisplayControlNotifier = { transitions.append("claim"); return true }
        fixture.view.surfaceOperations.text = { _, _ in transitions.append("write") }
        fixture.view.setMarkedText("hello", selectedRange: .init(location: 5, length: 0), replacementRange: noReplacement)
        #expect(transitions.isEmpty)
        fixture.view.insertText("hello", replacementRange: noReplacement)
        #expect(transitions == ["claim", "write"])
        fixture.view.takeDisplayControlNotifier = { transitions.append("denied"); return false }
        fixture.view.insertText("blocked", replacementRange: noReplacement)
        #expect(transitions == ["claim", "write", "denied"])
    }

    @Test("@spec KEY-1.9: When a key edits terminal text composition, the application shall keep that press, its repeats, and its release out of the terminal input stream, including after composition ends.")
    func compositionKeys() throws {
        let fixture = TextInputFixture()
        var directWrites: [Data] = []
        fixture.view.hostManagedInputWriter = { directWrites.append($0) }
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        fixture.view.keyDown(with: enter)
        #expect(directWrites.isEmpty)
        #expect(fixture.writes.isEmpty)
        let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        fixture.view.keyUp(with: release)
        fixture.view.cancelTextComposition()
        fixture.view.keyDown(with: enter)
        #expect(fixture.keyCodes == [36])
        #expect(directWrites.isEmpty)
    }

    @Test("Held editing keys continue reaching AppKit while composition is active",
          arguments: [UInt16(51), UInt16(123)])
    func activeCompositionKeyRepeat(keyCode: UInt16) throws {
        let fixture = TextInputFixture()
        var interpreted: [UInt16] = []
        fixture.view.surfaceOperations.interpretComposition = { _, event in
            interpreted.append(event.keyCode)
        }
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        fixture.view.keyDown(with: try fixture.keyEvent(keyCode, text: ""))
        fixture.view.keyDown(with: try fixture.keyEvent(keyCode, text: "", repeatKey: true))
        #expect(interpreted == [keyCode, keyCode])
        #expect(fixture.keyCodes.isEmpty)
        fixture.view.unmarkText()
        fixture.view.keyDown(with: try fixture.keyEvent(keyCode, text: "", repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(keyCode, text: "", type: .keyUp))
        #expect(interpreted == [keyCode, keyCode])
        #expect(fixture.keyCodes.isEmpty)
        #expect(fixture.writes.isEmpty)
    }

    @Test("A held composition key cannot submit input after composition ends")
    func compositionKeyRepeat() throws {
        let fixture = TextInputFixture()
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.unmarkText()
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r", repeatKey: true))
        #expect(fixture.keyCodes.isEmpty)
    }

    @Test("A fresh press after losing a composition key release keeps its own release")
    func freshKeyAfterComposition() throws {
        let fixture = TextInputFixture()
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.cancelTextComposition()
        // The old release can go to a different window after a focus change.
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.keyUp(with: try fixture.keyEvent(36, text: "\r", type: .keyUp))
        #expect(fixture.keyCodes == [36, 36])
    }

    @Test("@spec KEY-1.1: When a terminal receives ordinary text or Command-modified keyboard input outside text composition, the application shall forward the event to libghostty without duplicating text so terminal keybindings remain available.",
          arguments: [NSEvent.ModifierFlags(), .command, .control, .option, .shift])
    func ordinaryKeys(modifiers: NSEvent.ModifierFlags) throws {
        let fixture = TextInputFixture()
        fixture.view.keyDown(with: try fixture.keyEvent(0, text: "a", modifiers: modifiers))
        fixture.view.keyUp(with: try fixture.keyEvent(0, text: "a", type: .keyUp, modifiers: modifiers))
        #expect(fixture.keyCodes == [0, 0])
        #expect(fixture.writes.isEmpty)
    }

    @Test("Dictation indicator uses the terminal cursor in screen coordinates")
    func cursorGeometry() {
        let fixture = TextInputFixture()
        fixture.view.surfaceOperations.imeRect = { _ in NSRect(x: 40, y: 60, width: 10, height: 18) }
        let expected = fixture.window.convertToScreen(fixture.view.convert(NSRect(x: 40, y: 240, width: 0, height: 18), to: nil))
        #expect(fixture.view.firstRect(forCharacterRange: .init(location: 0, length: 0), actualRange: nil) == expected)
    }
}

@MainActor
private final class TextInputFixture {
    let view: SurfaceNSView
    let window: NSWindow
    var writes: [String] = []
    var preedits: [String] = []
    var keyCodes: [UInt32] = []

    init() {
        _ = NSApplication.shared
        view = SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.surfaceOperations = .init(setSize: { _, _, _ in }, size: { _ in .zero }, refresh: { _ in })
        view.surfaceOperations.setFocus = { _, _ in }
        view.surfaceOperations.key = { [weak self] _, key in
            self?.keyCodes.append(key.keycode)
            return true
        }
        view.surfaceOperations.text = { [weak self] _, text in self?.writes.append(text) }
        view.surfaceOperations.preedit = { [weak self] _, text in self?.preedits.append(text) }
        view.surfaceOperations.imeRect = { _ in .zero }
        window.contentView = view
        view.surface = UnsafeMutableRawPointer(bitPattern: 1)
        window.makeFirstResponder(view)
    }

    func keyEvent(_ code: UInt16, text: String, type: NSEvent.EventType = .keyDown,
                  modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeatKey, keyCode: code))
    }

    deinit {
        MainActor.assumeIsolated {
            view.surface = nil
            window.close()
        }
    }
}

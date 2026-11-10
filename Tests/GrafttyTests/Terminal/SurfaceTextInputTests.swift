import AppKit
import GhosttyKit
import Testing
import GrafttyCommandUI
import GrafttyProtocol
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

    @Test("@spec TEAM-15.13: When a Mac terminal dismisses worktree search for a cursor key or paste, the application shall discard the search query before forwarding the external edit.")
    func completionDismissalPrecedesCursorAndPaste() throws {
        let fixture = TextInputFixture()
        var delivered: [String] = []
        fixture.view.hostManagedInputWriter = { delivered.append(String(decoding: $0, as: UTF8.self)) }
        fixture.view.surfaceOperations.bindingAction = { _, action in delivered.append(action); return true }
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f"))
        fixture.view.keyDown(with: try fixture.keyEvent(123, text: ""))
        #expect(delivered == ["\u{1B}[D"])
        #expect(fixture.writes.isEmpty)
        fixture.view.agentCompletion.cancel(preserveLiteral: false)
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.pasteToTerminal(nil)
        #expect(delivered == ["\u{1B}[D", "paste_from_clipboard"])
        #expect(!fixture.view.agentCompletion.isActive)
    }

    @Test("@spec TEAM-15.14: If a Mac user accepts a picker row while a navigation key remains held, then the application shall consume repeats and release of that picker key until a new physical press.")
    func heldArrowCannotLeakAfterMouseAcceptance() async throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: {
            [.init(address: "/repo#codex", projectPath: "/repo", projectName: "repo", worktreePath: "/repo", worktreeName: "main", hostName: "Mac", runtime: "codex")]
        })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        await fixture.view.agentCompletion.waitForLoad()
        fixture.view.keyDown(with: try fixture.keyEvent(125, text: ""))
        fixture.view.agentCompletion.accept("/repo#codex")
        fixture.view.keyDown(with: try fixture.keyEvent(125, text: "", modifiers: .command, repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(125, text: "", type: .keyUp))
        #expect(fixture.keyCodes.isEmpty)
        #expect(fixture.writes == ["/repo#codex"])
        fixture.view.keyDown(with: try fixture.keyEvent(125, text: "", modifiers: .command))
        fixture.view.keyUp(with: try fixture.keyEvent(125, text: "", type: .keyUp, modifiers: .command))
        #expect(fixture.keyCodes == [125, 125])
    }

    @Test("Search cancellation does not write input or initiate host-managed takeover")
    func completionWriterDistinguishesSelectionFromCancellation() async throws {
        let fixture = TextInputFixture()
        var delivered: [String] = []
        var takeovers = 0
        fixture.view.hostManagedInputWriter = { delivered.append(String(decoding: $0, as: UTF8.self)) }
        fixture.view.canTakeDisplayControlNotifier = { takeovers == 0 }
        fixture.view.takeDisplayControlNotifier = { takeovers += 1; return true }
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: {
            [.init(address: "/repo#codex", projectPath: "/repo", projectName: "repo", worktreePath: "/repo", worktreeName: "main", hostName: "Mac", runtime: "codex")]
        })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.keyDown(with: try fixture.keyEvent(53, text: ""))
        #expect(delivered.isEmpty)
        #expect(takeovers == 0)
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        await fixture.view.agentCompletion.waitForLoad()
        fixture.view.agentCompletion.accept("/repo#codex")
        #expect(delivered == ["/repo#codex"])
        #expect(takeovers == 1)
    }

    @Test("@spec TEAM-15.19: When a user invokes Complete Worktree with the native Mac Cmd+Shift+K menu shortcut in an input-eligible terminal, the application shall open fuzzy search independently of the cursor boundary, retain terminal focus through modifier release, favor the current project while offering other projects, and leave ordinary percent input unchanged.")
    func nativeWorktreeSearchCommand() async throws {
        let fixture = TextInputFixture()
        let current = AgentCompletionCandidate(address: "/repo/fix#codex", projectPath: "/repo", projectName: "Repo", worktreePath: "/repo/fix", worktreeName: "fix", hostName: "Mac", runtime: "codex")
        let other = AgentCompletionCandidate(address: "/other/fix#codex", projectPath: "/other", projectName: "Other", worktreePath: "/other/fix", worktreeName: "fix", hostName: "Mac", runtime: "codex")
        fixture.view.configureAgentCompletion(currentWorktreePath: current.worktreePath, loader: { [other, current] })
        fixture.view.keyDown(with: try fixture.keyEvent(23, text: "%", modifiers: .shift))
        #expect(!fixture.view.agentCompletion.isActive)
        #expect(fixture.keyCodes == [23])
        fixture.view.agentCompletion.invalidateBoundary()
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Complete Worktree…", action: #selector(SurfaceNSView.completeWorktree(_:)), keyEquivalent: "K")
        item.keyEquivalentModifierMask = .command
        item.target = fixture.view
        #expect(menu.performKeyEquivalent(with: try fixture.keyEvent(40, text: "K", modifiers: [.command, .shift])))
        fixture.view.flagsChanged(with: try fixture.keyEvent(56, text: "", type: .flagsChanged, modifiers: .command))
        fixture.view.flagsChanged(with: try fixture.keyEvent(55, text: "", type: .flagsChanged))
        #expect(fixture.view.agentCompletion.isActive)
        #expect(fixture.window.firstResponder === fixture.view)
        await fixture.view.agentCompletion.waitForLoad()
        #expect(fixture.view.agentCompletion.candidates == [current, other])
        fixture.view.keyDown(with: try fixture.keyEvent(31, text: "oth"))
        fixture.view.keyDown(with: try fixture.keyEvent(49, text: " "))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "fx"))
        #expect(fixture.view.agentCompletion.candidates == [other])
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        #expect(fixture.writes == [other.address])
    }

    @Test("Native worktree search ignores unavailable, unfocused and composing terminals")
    func searchRequiresEligibleTerminal() {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        func invoke() { _ = fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil) }
        fixture.window.makeFirstResponder(nil)
        invoke()
        #expect(!fixture.view.agentCompletion.isActive)
        fixture.window.makeFirstResponder(fixture.view)
        fixture.view.isReadonly = true
        invoke()
        #expect(!fixture.view.agentCompletion.isActive)
        fixture.view.isReadonly = false
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        invoke()
        #expect(!fixture.view.agentCompletion.isActive)
        #expect(fixture.view.hasMarkedText())
        fixture.view.cancelTextComposition()
        fixture.view.surface = nil
        invoke()
        #expect(!fixture.view.agentCompletion.isActive)
    }

    @Test("A held completion shortcut stays consumed after its modifiers are released")
    func heldShortcutDoesNotEnterSearchQuery() throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        // AppKit already consumed the opening key press as a menu equivalent.
        fixture.view.agentCompletionShortcutKeyCode = 40
        fixture.view.keyDown(with: try fixture.keyEvent(40, text: "k", repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(40, text: "k", type: .keyUp))
        #expect(fixture.view.agentCompletion.query.isEmpty)
        #expect(fixture.keyCodes.isEmpty)
        fixture.view.keyDown(with: try fixture.keyEvent(40, text: "k"))
        #expect(fixture.view.agentCompletion.query == "k")
    }

    @Test("@spec TEAM-15.20: While native Mac worktree search is open, the application shall support multiword queries, keep an empty query open on Backspace, preserve the query on repeated invocation, consume Enter when no candidate matches, and discard the query on Escape without inserting terminal text.")
    func nativeSearchCancellation() throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.keyDown(with: try fixture.keyEvent(51, text: ""))
        #expect(fixture.view.agentCompletion.isActive)
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "foo bar"))
        fixture.view.flagsChanged(with: try fixture.keyEvent(55, text: "", type: .flagsChanged, modifiers: .command))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f", modifiers: .command, repeatKey: true))
        #expect(fixture.view.agentCompletion.query == "foo bar")
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.flagsChanged(with: try fixture.keyEvent(55, text: "", type: .flagsChanged))
        #expect(fixture.view.agentCompletion.query == "foo bar")
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.keyUp(with: try fixture.keyEvent(36, text: "\r", type: .keyUp))
        #expect(fixture.view.agentCompletion.isActive)
        fixture.view.keyDown(with: try fixture.keyEvent(53, text: ""))
        fixture.view.keyUp(with: try fixture.keyEvent(53, text: "", type: .keyUp))
        #expect(!fixture.view.agentCompletion.isActive)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.keyCodes == [55, 55])
    }

    @Test("@spec TEAM-15.7: When a Mac terminal accepts worktree search by keyboard, the application shall consume the query and acceptance presses, suppress their remaining repeats and releases, and deliver the selected agent address once through the terminal text path.")
    func macAgentCompletion() async throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: "/repo/fix", loader: {
            [.init(address: "/repo/fix#codex", projectPath: "/repo", projectName: "Repo", worktreePath: "/repo/fix", worktreeName: "fix", hostName: "This Mac", runtime: "codex")]
        })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f"))
        await fixture.view.agentCompletion.waitForLoad()
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.keyUp(with: try fixture.keyEvent(36, text: "\r", type: .keyUp))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f", repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(3, text: "f", type: .keyUp))
        #expect(fixture.keyCodes.isEmpty)
        #expect(fixture.writes == ["/repo/fix#codex"])
    }

    @Test("@spec TEAM-15.8: If an input-eligible Mac worktree search loses focus or begins composition or modified input, then the application shall discard its query before continuing the existing input path and shall not retain a hidden picker.")
    func macCompletionInterruption() throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f"))
        fixture.view.setMarkedText("compose", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.view.agentCompletion.isActive)
        #expect(fixture.view.hasMarkedText())
        fixture.view.cancelTextComposition()
        fixture.view.agentCompletion.cancel(preserveLiteral: false)
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        _ = fixture.view.resignFirstResponder()
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.view.agentCompletion.isActive)
    }

    @Test("@spec TEAM-15.16: While another display client owns a Mac pane, the application shall keep worktree search query edits and dismissal local without taking display control or sending terminal input.", arguments: [false, true])
    func completionDismissalDoesNotReclaimOwnership(dismissByEscape: Bool) throws {
        let fixture = TextInputFixture()
        fixture.view.configureAgentCompletion(currentWorktreePath: nil, loader: { [] })
        #expect(fixture.view.tryToPerform(#selector(SurfaceNSView.completeWorktree(_:)), with: nil))
        var takeovers = 0
        fixture.view.canTakeDisplayControlNotifier = { true }
        fixture.view.takeDisplayControlNotifier = { takeovers += 1; return true }
        fixture.view.keyDown(with: try fixture.keyEvent(3, text: "f"))
        fixture.view.insertText("ix", replacementRange: noReplacement)
        #expect(fixture.view.agentCompletion.query == "fix")
        if dismissByEscape {
            fixture.view.keyDown(with: try fixture.keyEvent(53, text: ""))
        } else {
            _ = fixture.view.resignFirstResponder()
        }
        #expect(takeovers == 0)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.view.agentCompletion.isActive)
    }

    @Test("@spec SLEEP-32: When a hardware key is released after a fresh prompt, the application shall forward its release without invalidating the prompt's acknowledged input boundary.")
    func keyReleasePreservesPromptBoundary() throws {
        let fixture = TextInputFixture()
        var presses = 0
        var releases = 0
        fixture.view.hostManagedUserInputScope = { body in presses += 1; body() }
        fixture.view.hostManagedReleaseInputScope = { body in releases += 1; body() }
        fixture.view.keyDown(with: try fixture.keyEvent(36, text: "\r"))
        fixture.view.keyUp(with: try fixture.keyEvent(36, text: "\r", type: .keyUp))
        #expect(presses == 1)
        #expect(releases == 1)
        #expect(fixture.keyCodes == [36, 36])
    }

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

    @Test("@spec KEY-1.11: When the focused terminal receives Control+Return or Control+keypad Enter as a key equivalent, the application shall dispatch the press and repeats through terminal input with modifiers preserved and consume the equivalent before AppKit opens a context menu.",
          arguments: [UInt16(36), 76], [NSEvent.ModifierFlags.control, [.control, .shift], [.control, .option], [.control, .capsLock]])
    func controlEnterKeyEquivalent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        let fixture = TextInputFixture()
        var actions: [ghostty_input_action_e] = []
        var directWrites: [Data] = []
        fixture.view.hostManagedInputWriter = { directWrites.append($0) }
        fixture.view.surfaceOperations.key = { _, key in
            #expect(key.keycode == UInt32(keyCode))
            #expect(key.mods == SurfaceNSView.ghosttyMods(from: modifiers))
            #expect(key.text == nil)
            actions.append(key.action)
            return true
        }
        let text = keyCode == 36 ? "\r" : "\u{3}"
        #expect(fixture.view.performKeyEquivalent(with: try fixture.keyEvent(keyCode, text: text, modifiers: modifiers)))
        #expect(fixture.view.performKeyEquivalent(with: try fixture.keyEvent(keyCode, text: text, modifiers: modifiers, repeatKey: true)))
        fixture.view.keyUp(with: try fixture.keyEvent(keyCode, text: text, type: .keyUp, modifiers: modifiers))
        #expect(actions == [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_REPEAT, GHOSTTY_ACTION_RELEASE])
        #expect(directWrites.isEmpty)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Control+Enter equivalents leave unfocused and unavailable terminals alone")
    func controlEnterRequiresFocusedSurface() throws {
        let fixture = TextInputFixture()
        let event = try fixture.keyEvent(36, text: "\r", modifiers: .control)
        fixture.window.makeFirstResponder(nil)
        #expect(!fixture.view.performKeyEquivalent(with: event))
        fixture.window.makeFirstResponder(fixture.view)
        fixture.view.surface = nil
        #expect(!fixture.view.performKeyEquivalent(with: event))
        #expect(fixture.keyCodes.isEmpty)
    }

    @Test("Control+Enter equivalents respect active text composition")
    func controlEnterDuringComposition() throws {
        let fixture = TextInputFixture()
        var interpreted = 0
        fixture.view.surfaceOperations.interpretComposition = { _, _ in interpreted += 1 }
        fixture.view.setMarkedText("pending", selectedRange: .init(location: 7, length: 0), replacementRange: noReplacement)
        #expect(fixture.view.performKeyEquivalent(with: try fixture.keyEvent(36, text: "\r", modifiers: .control)))
        fixture.view.unmarkText()
        fixture.view.keyUp(with: try fixture.keyEvent(36, text: "\r", type: .keyUp, modifiers: .control))
        #expect(interpreted == 1)
        #expect(fixture.keyCodes.isEmpty)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Other key equivalents keep normal AppKit dispatch",
          arguments: [UInt16(0), 36], [NSEvent.ModifierFlags(), .command])
    func unrelatedKeyEquivalents(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        let fixture = TextInputFixture()
        #expect(!fixture.view.performKeyEquivalent(with: try fixture.keyEvent(keyCode, text: keyCode == 36 ? "\r" : "a", modifiers: modifiers)))
        #expect(fixture.keyCodes.isEmpty)
    }

    @Test("@spec KEY-1.10: When a host-managed terminal receives Shift-modified editing or navigation keys, the application shall forward their presses, repeats, and releases to libghostty with Shift preserved instead of writing unmodified escape sequences.",
          arguments: [UInt16(0x33), 0x75, 0x73, 0x77, 0x74, 0x79, 0x7B, 0x7C, 0x7D, 0x7E])
    func shiftedHostManagedKeys(keyCode: UInt16) throws {
        let fixture = TextInputFixture()
        var directWrites: [Data] = []
        var actions: [ghostty_input_action_e] = []
        fixture.view.hostManagedInputWriter = { directWrites.append($0) }
        fixture.view.surfaceOperations.key = { _, key in
            #expect(key.keycode == UInt32(keyCode))
            #expect(key.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
            actions.append(key.action)
            return true
        }
        fixture.view.keyDown(with: try fixture.keyEvent(keyCode, text: "", modifiers: .shift))
        fixture.view.keyDown(with: try fixture.keyEvent(keyCode, text: "", modifiers: .shift, repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(keyCode, text: "", type: .keyUp, modifiers: .shift))
        #expect(directWrites.isEmpty)
        #expect(actions == [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_REPEAT, GHOSTTY_ACTION_RELEASE])
    }

    @Test("Changing Shift while holding Left preserves the Ghostty key release", arguments: [false, true])
    func shiftChangesDuringNavigation(initiallyShifted: Bool) throws {
        let fixture = TextInputFixture()
        var actions: [ghostty_input_action_e] = []
        fixture.view.hostManagedInputWriter = { _ in }
        fixture.view.surfaceOperations.key = { _, key in
            actions.append(key.action)
            return true
        }
        let initial: NSEvent.ModifierFlags = initiallyShifted ? .shift : []
        let changed: NSEvent.ModifierFlags = initiallyShifted ? [] : .shift
        fixture.view.keyDown(with: try fixture.keyEvent(0x7B, text: "\u{F702}", modifiers: initial))
        fixture.view.keyDown(with: try fixture.keyEvent(0x7B, text: "\u{F702}", modifiers: changed, repeatKey: true))
        fixture.view.keyDown(with: try fixture.keyEvent(0x7B, text: "\u{F702}", modifiers: initial, repeatKey: true))
        fixture.view.keyUp(with: try fixture.keyEvent(0x7B, text: "\u{F702}", type: .keyUp, modifiers: initial))
        let expected = initiallyShifted
            ? [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_REPEAT, GHOSTTY_ACTION_RELEASE]
            : [GHOSTTY_ACTION_REPEAT, GHOSTTY_ACTION_RELEASE]
        #expect(actions == expected)
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

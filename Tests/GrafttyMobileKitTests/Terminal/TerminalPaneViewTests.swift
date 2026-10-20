#if canImport(UIKit)
@testable import GhosttyTerminal
import GhosttyKit
import Testing
@testable import GrafttyMobileKit
import SwiftUI
import UIKit

private final class LinkTestLongPress: UILongPressGestureRecognizer {
    var point: CGPoint = .zero
    override var state: UIGestureRecognizer.State { get { .began } set {} }
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class NilInputKeyCommand: UIKeyCommand {
    override var input: String? { nil }
}

private final class ArrowTestKey: UIKey {
    var usage: UIKeyboardHIDUsage = .keyboardLeftArrow
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var characters: String {
        switch usage {
        case .keyboardRightArrow: UIKeyCommand.inputRightArrow
        case .keyboardUpArrow: UIKeyCommand.inputUpArrow
        case .keyboardDownArrow: UIKeyCommand.inputDownArrow
        default: UIKeyCommand.inputLeftArrow
        }
    }
    override var charactersIgnoringModifiers: String { characters }
    override var modifierFlags: UIKeyModifierFlags { [] }
}

private final class ArrowTestPress: UIPress {
    let arrow = ArrowTestKey()
    override var key: UIKey? { arrow }
}

@MainActor
private final class NativeInputDelegateSpy: NSObject, UITextInputDelegate {
    var events: [String] = []
    func textWillChange(_ textInput: (any UITextInput)?) { events.append("textWillChange") }
    func textDidChange(_ textInput: (any UITextInput)?) { events.append("textDidChange") }
    func selectionWillChange(_ textInput: (any UITextInput)?) { events.append("selectionWillChange") }
    func selectionDidChange(_ textInput: (any UITextInput)?) { events.append("selectionDidChange") }
    #if !targetEnvironment(macCatalyst)
    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
    #endif
}

private final class TerminalResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ data: Data) {
        lock.withLock { self.data.append(data) }
    }

    func snapshot() -> Data { lock.withLock { data } }
    func clear() { lock.withLock { data.removeAll() } }

    func contains(_ response: String) -> Bool {
        lock.withLock { data.range(of: Data(response.utf8)) != nil }
    }
}

@MainActor
private final class DeferredEditMenuAnimator: NSObject, UIEditMenuInteractionAnimating {
    private var completions: [() -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) {
        animations()
    }

    func addCompletion(_ completion: @escaping () -> Void) {
        completions.append(completion)
    }

    func finish() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
}

@Suite
@MainActor
struct TerminalPaneViewTests {

    @Test("@spec IOS-6.38: When the user toggles Auto-correct in the iOS keyboard accessory tray, the application shall enable or disable native terminal autocorrection without changing existing text or sending terminal input, default to off, and remember the preference across panes and app launches.")
    func autocorrectionTogglePreservesInputAndPreference() throws {
        #expect(SingleSessionView.terminalControlBarItems.contains(.autocorrection))
        #expect(UIImage(systemName: "textformat.abc") != nil)
        let suite = "TerminalAutocorrectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AppStorage(wrappedValue: false, SingleSessionView.autocorrectionDefaultsKey, store: defaults)
        #expect(!preference.wrappedValue)

        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let view = container.terminalView
        var output = ""
        container.committedSoftwareInput = .init(insertText: { output += $0 }, deleteBackward: { output.removeLast() })
        let host = UIViewController()
        host.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #expect(container.focusKeyboardInput())
        view.insertText("teh")
        #expect(view.autocorrectionType == .no)
        preference.wrappedValue = true
        view.isAutocorrectionEnabled = preference.wrappedValue
        #expect(view.autocorrectionType == .yes)
        #expect(view.isFirstResponder)
        #expect(output == "teh")
        let whole = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        #expect(view.text(in: whole) == "teh")

        // UIKit's correction uses the same retained range as dictation.
        view.replace(whole, withText: "the")
        #expect(output == "the")

        let restored = AppStorage(wrappedValue: false, SingleSessionView.autocorrectionDefaultsKey, store: defaults)
        let nextPane = TerminalInputContainerView(frame: .zero)
        nextPane.terminalView.isAutocorrectionEnabled = restored.wrappedValue
        #expect(nextPane.terminalView.autocorrectionType == .yes)
        preference.wrappedValue = false
        view.isAutocorrectionEnabled = false
        #expect(view.autocorrectionType == .no)
        #expect(view.isFirstResponder)
        #expect(!restored.wrappedValue)
        #expect(view.text(in: whole) == "the")
        #expect(output == "the")
        #expect(view.autocapitalizationType == .none)
        #expect(view.smartQuotesType == .no)
        #expect(view.smartDashesType == .no)
        #expect(view.inlinePredictionType == .no)
    }

    @Test("Changing autocorrection preserves an active marked composition")
    func autocorrectionPreservesMarkedText() throws {
        let container = TerminalInputContainerView(frame: .zero)
        var output = ""
        container.committedSoftwareInput = .init(insertText: { output += $0 }, deleteBackward: {})
        let view = container.terminalView
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        for enabled in [true, false] {
            view.isAutocorrectionEnabled = enabled
            let marked = try #require(view.markedTextRange)
            #expect(view.text(in: marked) == "にほん")
            #expect(output.isEmpty)
        }
    }

    @Test("@spec IOS-6.27: While native iOS dictation streams or revises terminal text, the application shall retain the text and UTF-16 positions reported to UIKit across commits, apply revisions without duplicating prior words, and clear that input context when terminal keyboard focus ends.")
    func dictationRetainsCommittedTextAndAppliesRevisions() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view: any UITextInput = container.terminalView
        let delegate = NativeInputDelegateSpy()
        var output = ""
        container.committedSoftwareInput = .init(
            insertText: { output += $0 },
            deleteBackward: { if !output.isEmpty { output.unicodeScalars.removeLast() } }
        )
        view.inputDelegate = delegate

        view.insertText("first")
        let firstEnd = view.endOfDocument
        #expect(view.offset(from: view.beginningOfDocument, to: firstEnd) == 5)
        let first = try #require(view.textRange(from: view.beginningOfDocument, to: firstEnd))
        #expect(view.text(in: first) == "first")
        #expect(view.position(from: view.beginningOfDocument, offset: 5) != nil)

        // Dictation may replace its prior hypothesis with a longer phrase.
        view.replace(first, withText: "first second")
        view.insertText(" 👋🏽")
        let whole = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        #expect(view.text(in: whole) == "first second 👋🏽")
        #expect(output == "first second 👋🏽")
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == output.utf16.count)
        view.deleteBackward()
        #expect(output == "first second 👋")
        #expect(view.text(in: try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))) == output)
        let phrase = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        view.replace(phrase, withText: "first third")
        #expect(output == "first third")
        #expect(view.text(in: try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))) == output)
        #expect(delegate.events.isEmpty)

        container.terminalView.resignFirstResponder()
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
    }

    @Test("Native composition retains earlier committed dictation context")
    func compositionFollowsCommittedDictationText() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view: any UITextInput = container.terminalView
        var texts: [String] = []
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: {})
        view.insertText("first ")
        view.setMarkedText("second", selectedRange: NSRange(location: 6, length: 0))
        let marked = try #require(view.markedTextRange)
        #expect(view.offset(from: view.beginningOfDocument, to: marked.start) == 6)
        #expect(view.text(in: marked) == "second")
        #expect(texts == ["first "])
        view.unmarkText()
        #expect(view.markedTextRange == nil)
        #expect(texts == ["first ", "second"])
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 12)
        view.insertText(" third")
        #expect(texts == ["first ", "second", " third"])
    }

    @Test("Software Return and lost input eligibility clear dictation context")
    func dictationContextEndsAtTerminalCommandBoundaries() {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: { deletes += 1 })
        view.insertText("first")
        view.insertText("\n")
        #expect(texts == ["first", "\n"])
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
        // The remote prompt can contain text outside this local context.
        view.deleteBackward()
        #expect(deletes == 1)
        view.insertText("next")
        container.committedSoftwareInput = nil
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
        view.insertText("ignored")
        #expect(texts == ["first", "\n", "next"])
    }

    #if !targetEnvironment(macCatalyst)
    @Test("Sticky Ctrl replacements and deletes bypass retained dictation text", arguments: [true, false])
    func stickyControlDoesNotReviseDictationContext(replacing: Bool) throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: { deletes += 1 })
        view.insertText("abc")
        view.toggleStickyModifier(.ctrl)
        if replacing {
            let range = try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
            view.replace(range, withText: "c")
        } else {
            view.deleteBackward()
        }
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
        #expect(texts == ["abc"])
        #expect(deletes == 0)
        #expect(view.stickyActivation(for: .ctrl) == .inactive)
    }
    #endif

    @Test("Correcting committed dictation preserves a separate active composition")
    func correctingCommittedWordPreservesComposition() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var output = ""
        container.committedSoftwareInput = .init(
            insertText: { output += $0 }, deleteBackward: { if !output.isEmpty { output.unicodeScalars.removeLast() } }
        )
        view.insertText("first ")
        view.setMarkedText("secon", selectedRange: NSRange(location: 5, length: 0))
        let end = try #require(view.position(from: view.beginningOfDocument, offset: 5))
        let word = try #require(view.textRange(from: view.beginningOfDocument, to: end))
        view.replace(word, withText: "First")
        #expect(output == "First ")
        #expect(view.markedTextRange != nil)
        view.setMarkedText("second", selectedRange: NSRange(location: 6, length: 0))
        view.unmarkText()
        #expect(output == "First second")
    }

    @Test("Hardware command dispatch clears prior software dictation context")
    func hardwareReturnEndsDictationContext() {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var texts: [String] = []
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: {})
        view.insertText("first")
        container.performHardwareKeyboardCommandForTesting(input: "\r", modifierFlags: [])
        #expect(texts == ["first", "\r"])
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 0)
    }

    @Test("Menu paste clears dictation context before inserting remote text")
    func menuPasteEndsDictationContext() {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        view.insertText("first")
        var contextLengthAtPaste: Int?
        container.onPasteRequested = {
            contextLengthAtPaste = view.offset(from: view.beginningOfDocument, to: view.endOfDocument)
        }
        container.performPasteForTesting()
        #expect(contextLengthAtPaste == 0)
    }

    #if !targetEnvironment(macCatalyst)
    @Test("Arming Ctrl preserves marked text while selecting and deleting it")
    func stickyControlDoesNotTransformPendingComposition() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var texts: [String] = []
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: {})
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        view.toggleStickyModifier(.ctrl)
        let selected = try #require(view.position(from: view.beginningOfDocument, offset: 2))
        view.selectedTextRange = view.textRange(from: selected, to: selected)
        view.deleteBackward()
        #expect(view.text(in: try #require(view.markedTextRange)) == "ac")
        #expect(view.stickyActivation(for: .ctrl) == .armed)
        view.commitAndResetTextContext()
        #expect(texts == ["ac"])
        #expect(view.stickyActivation(for: .ctrl) == .armed)
        #expect(view.markedTextRange == nil)
    }

    @Test("Sticky marked-text deletion retains Ghostty's native text and selection")
    func stickyMarkedDeletionMatchesNativeContext() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        var texts: [String] = []
        container.committedSoftwareInput = .init(insertText: { texts.append($0) }, deleteBackward: {})
        view.setMarkedText("👋🏽", selectedRange: NSRange(location: 4, length: 0))
        view.toggleStickyModifier(.ctrl)
        view.deleteBackward()
        let nativeRange = try #require(view.inputHandler.markedTextRange())
        let nativeText = try #require(view.inputHandler.text(in: nativeRange))
        #expect(view.text(in: try #require(view.markedTextRange)) == nativeText)
        let nativeSelection = view.inputHandler.selectedTextRange()
        #expect(view.offset(from: view.beginningOfDocument, to: try #require(view.selectedTextRange).start) == nativeSelection.location)
        view.unmarkText()
        #expect(texts == [nativeText])
        #expect(view.stickyActivation(for: .ctrl) == .armed)
    }
    #endif

    @Test("Prefix revisions keep a selection inside removed text within the document")
    func prefixRevisionClampsRemovedSelection() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        view.insertText("abcdefghij")
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
        let caret = try #require(view.position(from: view.beginningOfDocument, offset: 5))
        view.selectedTextRange = view.textRange(from: caret, to: caret)
        let prefixEnd = try #require(view.position(from: view.beginningOfDocument, offset: 10))
        view.replace(try #require(view.textRange(from: view.beginningOfDocument, to: prefixEnd)), withText: "")
        let selected = try #require(view.selectedTextRange)
        #expect(view.offset(from: view.beginningOfDocument, to: selected.start) == 0)
        #expect(view.offset(from: view.beginningOfDocument, to: selected.end) <= 1)
        // Validate the selection before passing it to NSString insertion.
        try #require(view.offset(from: view.beginningOfDocument, to: selected.end) <= 1)
        view.unmarkText()
        view.insertText("y")
        #expect(view.text(in: try #require(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))) == "yx")
    }

    @Test("External terminal controls notify UIKit when they reset input context")
    func externalInputContextResetNotifiesUIKit() {
        let container = TerminalInputContainerView(frame: .zero)
        let view = container.terminalView
        let delegate = NativeInputDelegateSpy()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        view.inputDelegate = delegate
        view.insertText("first")
        #expect(delegate.events.isEmpty)
        view.commitAndResetTextContext()
        #expect(delegate.events == ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"])
        delegate.events.removeAll()
        view.commitAndResetTextContext()
        view.insertText("next")
        #expect(delegate.events.isEmpty)
        // Physical input clears context before Ghostty delegates Return.
        view.pressesBegan([], with: nil)
        #expect(delegate.events == ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"])
        delegate.events.removeAll()
        view.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        #expect(container.terminalView(view, handleHardwareKey: TerminalHardwareKeyEvent(
            usage: UInt16(UIKeyboardHIDUsage.keyboardA.rawValue), characters: "\u{01}",
            charactersIgnoringModifiers: "a", modifierFlags: [.control]
        )))
        #expect(delegate.events == ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"])
        #expect(view.markedTextRange == nil)
        delegate.events.removeAll()
        view.setMarkedText("pending\n", selectedRange: NSRange(location: 8, length: 0))
        view.commitAndResetTextContext()
        #expect(delegate.events == ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"])
    }

    @Test("@spec IOS-6.28: While a hardware arrow key is held in a mobile terminal, the application shall use its own repeat scheduler with libghostty's automatic repeat disabled, repeat that key after an initial delay, and stop repeating on release, cancellation, keyboard ineligibility, focus loss, or dismissal of the agent picker that received the held arrow.", arguments: [UIKeyboardHIDUsage.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow])
    func heldArrowRepeatsAndStops(usage: UIKeyboardHIDUsage) async throws {
        let container = TerminalInputContainerView(frame: .zero)
        #expect(!container.terminalView.automaticallyRepeatsHardwareKeys)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var delivered = 0
        let press = ArrowTestPress()
        press.arrow.usage = usage
        container.hardwareKeyboardCommands = [.init(id: "arrow", title: "Arrow",
            input: press.arrow.characters, modifierFlags: [], perform: { delivered += 1 })]
        container.terminalView.pressesBegan([press], with: nil)
        #expect(delivered == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered == 1)
        try await Task.sleep(for: .milliseconds(550))
        #expect(delivered > 1)
        container.terminalView.pressesEnded([press], with: nil)
        let releasedCount = delivered
        try await Task.sleep(for: .milliseconds(150))
        #expect(delivered == releasedCount)
        container.terminalView.pressesBegan([press], with: nil)
        container.terminalView.pressesCancelled([press], with: nil)
        let cancelledCount = delivered
        try await Task.sleep(for: .milliseconds(650))
        #expect(delivered == cancelledCount)
        container.terminalView.pressesBegan([press], with: nil)
        container.committedSoftwareInput = nil
        let disabledCount = delivered
        try await Task.sleep(for: .milliseconds(650))
        #expect(delivered == disabledCount)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        container.terminalView.pressesBegan([press], with: nil)
        _ = container.terminalView.resignFirstResponder()
        let unfocusedCount = delivered
        try await Task.sleep(for: .milliseconds(650))
        #expect(delivered == unfocusedCount)
    }

    @Test("first-line clearance preserves the full scroll viewport and excludes chrome from terminal input")
    func terminalClearancePreservesFullScrollViewport() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.reservesTopChromeSpace = true
        let displayScale = UIScreen.main.scale
        container.terminalView.contentScaleFactor = displayScale
        container.terminalDidResize(TerminalGridMetrics(
            columns: 40, rows: 12, widthPixels: 640, heightPixels: 480,
            cellWidthPixels: 16, cellHeightPixels: 40))
        container.layoutIfNeeded()
        #expect(container.snapshotScrollView.frame == container.bounds)
        #expect(abs(container.terminalView.frame.minY - 40 / displayScale) < 0.001)
        #expect(container.terminalView.frame.maxY == 240)
        #expect(!container.acceptsTerminalInput(at: CGPoint(x: 160, y: 1)))
        #expect(container.acceptsTerminalInput(at: CGPoint(x: 160, y: 40 / displayScale + 1)))
        #expect(container.acceptsTerminalInput(at: CGPoint(x: 160, y: 239)))
        container.onBackRequested = {}
        container.layoutIfNeeded()
        #expect(container.terminalView.frame.minY >= 68)
        #expect(container.terminalView.frame.maxY == 240)
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.layoutIfNeeded()
        #expect(container.snapshotScrollView.frame == container.bounds)
        #expect(container.terminalView.bounds.size == CGSize(width: 1280 / displayScale, height: 960 / displayScale))
    }

    @Test("a tall follower keeps its protected first line visible, including after zoom", arguments: [CGFloat(1), CGFloat(2)])
    func overflowingFollowerProtectsFirstLine(zoom: CGFloat) {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 160))
        container.reservesTopChromeSpace = true
        container.onBackRequested = {}
        container.terminalView.contentScaleFactor = UIScreen.main.scale
        container.terminalDidResize(TerminalGridMetrics(
            columns: 80, rows: 24, widthPixels: 1200, heightPixels: 800,
            cellWidthPixels: 15, cellHeightPixels: 33))
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.layoutIfNeeded()
        container.snapshotScrollView.setFollowerZoomScale(zoom, around: CGPoint(x: 300, y: 80))
        container.layoutIfNeeded()
        let firstRow = container.terminalView.convert(CGPoint.zero, to: container)
        #expect(firstRow.y >= 68)
        #expect(container.snapshotScrollView.contentOffset.y == 0)
        #expect(abs(container.snapshotScrollView.contentOffset.x - 300 * (zoom - 1)) < 1)
        #expect(container.snapshotScrollView.frame == container.bounds)
    }

    @Test("@spec IOS-6.24: When the iOS text input system inserts, replaces, selects, or composes terminal text, the application shall deliver committed text once without reporting those same edits back to the input delegate as external changes.")
    func nativeInputDoesNotEchoExternalChangeNotifications() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let view: any UITextInput = container.terminalView
        let delegate = NativeInputDelegateSpy()
        var texts: [String] = []
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) }, deleteBackward: {}
        )
        view.inputDelegate = delegate

        view.insertText("first ")
        view.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
        #expect(texts == ["first "])
        let range = try #require(view.markedTextRange)
        view.selectedTextRange = view.textRange(from: range.start, to: range.start)
        view.replace(range, withText: "second ")
        view.setMarkedText("third!", selectedRange: NSRange(location: 6, length: 0))
        view.deleteBackward()
        view.unmarkText()

        #expect(texts == ["first ", "second ", "third"])
        #expect(delegate.events.isEmpty)
        // Genuine changes originating outside UIKit still reach its delegate.
        #expect(view.inputDelegate === delegate)
        view.inputDelegate?.selectionWillChange(view)
        view.inputDelegate?.selectionDidChange(view)
        #expect(delegate.events == ["selectionWillChange", "selectionDidChange"])
    }

    @Test("@spec IOS-6.23: While the user has hidden the mobile keyboard, the application shall reject terminal keyboard focus requests without disabling scrolling, and restore focus eligibility when the user chooses Show keyboard.")
    func hiddenKeyboardRejectsTouchFocusUntilShown() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIViewController()
        host.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let input = TerminalPaneView.CommittedSoftwareInput(insertText: { _ in }, deleteBackward: {})
        for keyboardAllowed in [true, false, false, true] {
            container.committedSoftwareInput = SingleSessionView.isTerminalKeyboardEligible(
                clientIsOwner: true,
                isPaneFocused: true,
                keyboardAllowed: keyboardAllowed
            ) ? input : nil

            #expect(container.terminalView.canBecomeFirstResponder == keyboardAllowed)
            // Ghostty requests focus from touchesBegan before recognizing a scroll.
            #expect(container.terminalView.becomeFirstResponder() == keyboardAllowed)
            #expect(container.terminalView.isFirstResponder == keyboardAllowed)
            #expect(container.terminalView.gestureRecognizers?
                .compactMap { $0 as? UIPanGestureRecognizer }
                .contains { $0.isEnabled } == true)
        }
    }

    @Test("@spec IOS-4.46: When a retained mobile pane releases its follower canvas while its route callbacks are detached, the application shall preserve the pending physical viewport confirmation and deliver it once after the route restores its callback.")
    func canvasReleaseWaitsForRestoredViewportCallback() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        container.layoutIfNeeded()
        let scale = container.terminalView.contentScaleFactor
        container.terminalDidResize(TerminalGridMetrics(
            columns: 80, rows: 24, widthPixels: UInt32(600 * scale), heightPixels: UInt32(400 * scale),
            cellWidthPixels: UInt32(7.5 * scale), cellHeightPixels: UInt32(16.5 * scale)
        ))
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.layoutIfNeeded()
        // RetainedMobilePane.detachControls removes this callback on route exit.
        container.onPhysicalViewportReady = nil
        container.authoritativeGrid = nil
        container.layoutIfNeeded()
        container.layoutIfNeeded()
        #expect(container.terminalView.bounds.size == container.bounds.size)
        #expect(container.terminalView.contentScaleFactor == scale)
        var reported: [InMemoryTerminalViewport] = []
        container.onPhysicalViewportReady = { reported.append($0) }
        container.layoutIfNeeded()
        #expect(reported.count == 1)
        #expect(reported.first?.columns == 80)
        #expect(reported.first?.rows == 24)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(reported.count == 1)
    }

    @Test("Canvas release confirms an unchanged physical viewport without awaiting a deduplicated resize", arguments: [CGSize.zero, CGSize(width: 0.1, height: 0.1), CGSize(width: 300, height: -100)])
    func canvasReleaseConfirmsViewportOnlyWithoutResize(sizeChange: CGSize) {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        container.terminalView.contentScaleFactor = 2
        container.terminalDidResize(TerminalGridMetrics(
            columns: 80, rows: 24, widthPixels: 1200, heightPixels: 800,
            cellWidthPixels: 15, cellHeightPixels: 33
        ))
        container.authoritativeGrid = .init(cols: 80, rows: 24)
        container.layoutSubviews()
        var reported: [InMemoryTerminalViewport] = []
        container.onPhysicalViewportReady = { reported.append($0) }
        container.frame.size = CGSize(width: 600 + sizeChange.width, height: 400 + sizeChange.height)
        container.authoritativeGrid = nil
        container.layoutSubviews()
        container.layoutSubviews()
        let requiresResize = sizeChange.width >= 1
        #expect(reported.count == (requiresResize ? 0 : 1))
        if !requiresResize {
            #expect(reported.first?.columns == 80)
            #expect(reported.first?.rows == 24)
        } else {
            // The delayed native canvas metrics cannot confirm the physical grid.
            container.terminalDidResize(TerminalGridMetrics(
                columns: 80, rows: 24, widthPixels: 1200, heightPixels: 800,
                cellWidthPixels: 15, cellHeightPixels: 33
            ))
            #expect(reported.isEmpty)
            container.terminalDidResize(TerminalGridMetrics(
                columns: 120, rows: 18, widthPixels: 1800, heightPixels: 600,
                cellWidthPixels: 15, cellHeightPixels: 33
            ))
            #expect(reported.count == 1)
            #expect(reported.first?.columns == 120)
            #expect(reported.first?.rows == 18)
            container.layoutSubviews()
            #expect(reported.count == 1)
        }
    }

    @Test("@spec IOS-11.13: When the user presses and holds a displayed HTTP or HTTPS URL whose terminal cells map unambiguously to the viewport text, the application shall offer Open Link alongside its text-selection actions and offer Copy Link and route the complete URL through the originating pane browser when Open Link is chosen. Pressing ordinary text shall not offer link actions.")
    func longPressOpensTheCompleteURLUnderThePressedWord() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let text = "See https://example.com/first and https://example.org/path?q=hello#part."
        container.terminalView.contentScaleFactor = 1
        container.terminalDidResize(TerminalGridMetrics(
            columns: 100, rows: 1, widthPixels: 1000, heightPixels: 20,
            cellWidthPixels: 10, cellHeightPixels: 20
        ))
        var opened: [URL] = []
        container.openURL = { opened.append($0) }
        container.prepareLongPressMenu(
            at: CGPoint(x: CGFloat((text as NSString).range(of: "hello").location) * 10 + 5, y: 10),
            text: text
        )
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Open Link", "Copy Link", "Select", "Select All",
        ])
        let action = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Open Link" })
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened.map(\.absoluteString) == ["https://example.org/path?q=hello#part"])
        #expect(!container.selectionController.isActive)

        container.prepareLongPressMenu(
            at: CGPoint(x: 5, y: 10), text: text
        )
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Select", "Select All",
        ])
        button.sendActions(for: .touchUpInside)
        #expect(opened.count == 1, "A dismissed menu must not open a stale URL")
    }

    @Test("@spec IOS-11.24: If a terminal link menu outlives its originating session or ownership context, then the application shall discard its Open and Copy actions instead of invoking callbacks for a replacement pane.")
    func staleLinkMenuCannotUseReplacementContext() throws {
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.contentScaleFactor = 1
        container.linkContext = "owned-first-pane"
        container.terminalDidResize(TerminalGridMetrics(columns: 100, rows: 1, widthPixels: 1000, heightPixels: 20, cellWidthPixels: 10, cellHeightPixels: 20))
        var opened = 0
        var copied = 0
        container.openURL = { _ in opened += 1 }
        container.copyLink = { _ in copied += 1 }
        container.prepareLongPressMenu(at: CGPoint(x: 105, y: 10), text: "https://example.com/first")
        let actions = container.longPressMenuForTesting(hasPasteContent: false).children.compactMap { $0 as? UIAction }.filter { $0.title.contains("Link") }
        try #require(actions.count == 2)
        container.linkContext = "unowned-first-pane"
        container.linkContext = "owned-replacement-pane"
        for action in actions {
            let button = UIButton()
            button.addAction(action, for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
        }
        #expect(opened == 0)
        #expect(copied == 0)
    }

    @Test
    func terminalLinksRejectMissingGeometryAndUnsupportedSchemes() {
        let container = TerminalInputContainerView(frame: .zero)
        container.prepareLongPressMenu(at: .zero, text: "https://example.com/path")
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        #expect(TerminalLinkResolver.webURL("file:///tmp/file") == nil)
        #expect(TerminalLinkResolver.webURL("javascript:alert(1)") == nil)
    }

    @Test
    func terminalLinksUsePhysicalRowsAfterASCIIWrapping() {
        let grid = TerminalGridMetrics(
            columns: 40, rows: 12, widthPixels: 400, heightPixels: 240,
            cellWidthPixels: 10, cellHeightPixels: 20
        )
        let text = String(repeating: "a", count: 50)
            + "\n\nhttps://one.example/same\nhttps://two.example/same"
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 215, y: 90), grid: grid, displayScale: 1
        )?.absoluteString == "https://two.example/same")
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 215, y: 50), grid: grid, displayScale: 1
        ) == nil)

        let wrappedURL = "https://example.com/" + String(repeating: "path", count: 15)
        #expect(TerminalLinkResolver.url(
            in: wrappedURL, at: CGPoint(x: 45, y: 30), grid: grid, displayScale: 1
        )?.absoluteString == wrappedURL)
        #expect(TerminalLinkResolver.url(
            in: "界\n" + wrappedURL, at: CGPoint(x: 45, y: 30), grid: grid, displayScale: 1
        ) == nil)
    }

    @Test
    func nativeAnchorsRequireFullURLContainment() {
        let text = "● 🧪 https://one.example/same?q=first https://two.example/same?q=A%2Bb#part"
        let full = text as NSString
        let anchor = full.range(of: "A%2Bb")
        #expect(TerminalLinkResolver.url(in: text, anchor: anchor)?.absoluteString == "https://two.example/same?q=A%2Bb#part")
        #expect(TerminalLinkResolver.url(in: text, anchor: full.range(of: "●")) == nil)
        #expect(TerminalLinkResolver.url(in: text, anchor: NSRange(location: anchor.location, length: full.length)) == nil)
        #expect(TerminalLinkResolver.webURL("https://user:secret@example.com/") == nil)
    }

    @Test
    func terminalLinksRequireEveryPossiblePaddedCellToMatch() {
        let grid = TerminalGridMetrics(
            columns: 40, rows: 10, widthPixels: 420, heightPixels: 200,
            cellWidthPixels: 10, cellHeightPixels: 20
        )
        let text = "https://example.com/path ordinary"
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 50, y: 5), grid: grid, displayScale: 2
        )?.absoluteString == "https://example.com/path")
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 120, y: 5), grid: grid, displayScale: 2
        ) == nil)
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 2.5, y: 5), grid: grid, displayScale: 2
        ) == nil, "A possible left margin must not count as the URL's first cell")
        var paddedVertically = grid
        paddedVertically.heightPixels = 220
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 50, y: 2.5), grid: paddedVertically, displayScale: 2
        ) == nil, "A possible top margin must not count as the URL's first row")
    }

    @Test("@spec IOS-11.23: When a native terminal long-press or Cmd-click targets a plain or OSC8 link in an unselected terminal without mouse capture after Unicode output and soft wraps, the application shall recognize and route the exact hyperlink target without installing another gesture.", arguments: [0, 1, 2, 5, 6])
    func realSurfaceLinksResolveAfterWrappedOutput(fixture: Int) async throws {
        try await verifyRealSurfaceLinks(fixture: fixture)
    }

    @Test("@spec IOS-11.25: While a terminal application captures mouse input or a native selection is active, the application shall retain text-selection actions and omit long-press link actions whose OSC8 target cannot be verified without changing that input state.", arguments: [3, 4, 7, 8])
    func protectedNativeLinksRetainSelection(fixture: Int) async throws {
        try await verifyRealSurfaceLinks(fixture: fixture)
    }

    private func verifyRealSurfaceLinks(fixture: Int) async throws {
        let osc8 = fixture == 1 || fixture >= 5
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        container.layoutIfNeeded()
        let responses = TerminalResponseRecorder()
        let session = InMemoryTerminalSession(write: { responses.append($0) }, resize: { _ in })
        let renderer = MobileTerminalControllerFactory.make(configText: "font-size = 14\nlink-previews = \(fixture != 2 && fixture != 5 && fixture != 6)")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = renderer
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer {
            container.removeFromSuperview()
            window.isHidden = true
        }
        let grid = try #require(container.terminalGridMetrics)
        try #require(grid.rows >= 8)
        // Public UI metrics arrive before the parser resizes. A cursor
        // clamped to the bottom-right proves the parser reached this grid
        // before the fixture can wrap and scroll at its startup dimensions.
        let bottomRight = "\u{1b}[\(grid.rows);\(grid.columns)R"
        for _ in 0..<100 where !responses.contains(bottomRight) {
            session.receive("\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(responses.contains(bottomRight))
        let prefix = "● 🧪 Unicode prompt " + String(repeating: "a", count: Int(grid.columns) - 14)
        let target = fixture == 6 ? "file:///tmp/private-fixture.txt"
            : "https://two.example/" + String(repeating: "path", count: Int(grid.columns) / 2) + "?q=A%2Bb#part"
        let label = fixture >= 5 ? "https://label.example/advertised" : (osc8 ? "Sign in to second service" : target)
        let link = osc8 ? "\u{1b}]8;;\(target)\u{1b}\\\(label)\u{1b}]8;;\u{1b}\\" : target
        session.receive("\u{1b}[H\u{1b}[2J" + prefix + "\r\n\r\nhttps://one.example/same\r\n" + link)
        for _ in 0..<100 where session.readViewportText()?.contains(label) != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try #require(session.readViewportText())
        #expect(container.terminalGridMetrics == grid)
        #expect(text.hasPrefix(prefix + "\n\n"), "Soft wraps join, while hard blank rows remain. Grid: \(grid)")
        let cellHeight = CGFloat(grid.cellHeightPixels)
        let unusedHeight = CGFloat(grid.heightPixels) - CGFloat(grid.rows) * cellHeight
        try #require(unusedHeight < cellHeight)
        let scale = container.terminalView.contentScaleFactor
        let point = CGPoint(
            x: CGFloat(grid.cellWidthPixels) * 15.5 / scale,
            y: (cellHeight * 4 + (cellHeight + unusedHeight) / 2) / scale
        )
        let surface = try #require(container.terminalView.surface)
        if fixture == 3 || fixture == 7 {
            surface.sendMousePos(x: -1, y: -1)
            session.receive("\u{1b}[?1003h\u{1b}[?1006h")
            for _ in 0..<100 where !surface.isMouseCaptured { try await Task.sleep(for: .milliseconds(10)) }
            try #require(surface.isMouseCaptured)
        } else if fixture == 4 || fixture == 8 {
            container.selectionController.beginSelection(at: CGPoint(x: 20, y: 10))
            try #require(container.selectionController.isActive)
        }
        let before = responses.snapshot().count
        var opened: URL?
        container.openURL = { opened = $0 }
        let gesture = LinkTestLongPress()
        gesture.point = point
        container.terminalView.handleLongPressForSelection(gesture)
        if [3, 4, 7, 8].contains(fixture) {
            let titles = container.longPressMenuActionTitlesForTesting(hasPasteContent: false)
            #expect(!titles.contains("Open Link"))
            #expect(!titles.contains("Copy Link"))
            #expect(titles.contains("Select"))
            if fixture == 3 || fixture == 7 {
                try await Task.sleep(for: .milliseconds(20))
                let report = String(decoding: responses.snapshot().dropFirst(before), as: UTF8.self)
                #expect(report.components(separatedBy: "\u{1b}[<").count - 1 == 1,
                        "Only the wrapper's original move may report to the mouse-capturing application")
            } else { #expect(container.selectionController.isActive) }
            return
        }
        if fixture == 6 {
            #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
            #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Copy Link"))
            surface.sendMousePos(x: -1, y: -1, modifiers: .super_)
            surface.sendMousePos(x: Double(point.x), y: Double(point.y), modifiers: .super_)
            _ = surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
            _ = surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
            #expect(opened == nil, "Unsupported OSC8 targets must neither open nor fall back to the visible label URL")
            return
        }
        let action = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Open Link" })
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened?.absoluteString == target)
        var copied: URL?
        container.copyLink = { copied = $0 }
        let copy = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Copy Link" })
        let copyButton = UIButton()
        copyButton.addAction(copy, for: .touchUpInside)
        copyButton.sendActions(for: .touchUpInside)
        #expect(copied?.absoluteString == target)
        if osc8 {
            opened = nil
            let surface = try #require(container.terminalView.surface)
            surface.sendMousePos(x: -1, y: -1, modifiers: .super_)
            surface.sendMousePos(x: Double(point.x), y: Double(point.y), modifiers: .super_)
            _ = surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
            _ = surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: .super_)
            #expect(opened?.absoluteString == target, "Actual native OSC8 Cmd-click must invoke the Graftty callback")
        }
    }

    @Test("@spec PORTS-5.18: When a mobile user opens an OAuth terminal link, the application shall route its exact URL through the originating pane browser without a separate sign-in action or stale menu targets.")
    func authLinksUsePaneBrowser() throws {
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.contentScaleFactor = 1
        container.terminalDidResize(TerminalGridMetrics(
            columns: 200, rows: 1, widthPixels: 2000, heightPixels: 20,
            cellWidthPixels: 10, cellHeightPixels: 20
        ))
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback&state=test")!
        var opened: [URL] = []
        container.openURL = { opened.append($0) }
        container.prepareLongPressMenu(at: CGPoint(x: 105, y: 10), text: url.absoluteString)
        let action = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Open Link" })
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Sign in via Mac"))
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened == [url])
        container.prepareLongPressMenu(at: CGPoint(x: 105, y: 10), text: "https://example.com/ordinary-link")
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Sign in via Mac"))
        button.sendActions(for: .touchUpInside)
        #expect(opened == [url])
    }

    @Test("When the terminal surface is replaced, selection and cached link targets are discarded")
    func detachedSurfaceClearsSelectionAndLinks() {
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.contentScaleFactor = 1
        container.terminalDidResize(TerminalGridMetrics(
            columns: 100, rows: 1, widthPixels: 1000, heightPixels: 20,
            cellWidthPixels: 10, cellHeightPixels: 20
        ))
        container.selectionController.beginSelection(at: .zero)
        container.enterSelectionModeForTesting()
        container.prepareLongPressMenu(at: CGPoint(x: 100, y: 10), text: "https://example.com/old-surface")
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        container.terminalDidDetachSurface()
        #expect(!container.selectionController.isActive)
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        container.prepareLongPressMenu(at: .zero, text: "New text")
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test
    func terminalDoesNotExposeGhosttyAccessoryView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, `UITerminalView` shall remain the sole terminal keyboard responder and its supported `showsInputAccessory` property shall be false, so the GhosttyKit accessory is absent without Objective-C runtime swizzling. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func terminalPaneShowsOnlyGrafttyKeyboardAccessory() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.8: While no authoritative checkpoint grid is set, the terminal shall fill the padded viewport, remain its rendering touch target, and retain libghostty-spm's built-in pan-to-scroll and pinch-to-zoom gestures.
""")
    func terminalViewIsSoleFullSizeSubviewAndTouchTarget() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(container.terminalView.superview === container.snapshotScrollView)
        #expect(!container.snapshotScrollView.isScrollEnabled)
        #expect(container.terminalView.frame == container.bounds)
        #expect(hitView === container.terminalView)
        #expect(!container.terminalView.canBecomeFirstResponder)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        #expect(container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.17: While a terminal pane is rendered on iPad with a trackpad, indirect pointer scroll gestures shall reach libghostty's terminal scroll/input recognizers on the sole `UITerminalView` touch surface, with no GrafttyMobile keyboard or selection overlay blocking them.
""")
    func terminalPanRecognizersAllowIndirectScrolling() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test("""
@spec IOS-11.1: While a focused terminal pane is interactive, the application shall handle libghostty's built-in long-press selection request through `TerminalInputContainerView` and present a menu at the touch point containing **Select**, **Select All**, and (when the clipboard contains text or an image at menu-build time) **Paste**, without installing a competing long-press recognizer on the container.
""")
    func terminalLongPressUsesGhosttySelectionRequestDelegate() throws {
        let container = TerminalInputContainerView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let terminalLongPress = try #require(
            container.terminalView.gestureRecognizers?
                .compactMap { $0 as? UILongPressGestureRecognizer }
                .first
        )

        #expect(container.terminalView.delegate === container)
        #expect(container.terminalView.gestureRecognizerShouldBegin(terminalLongPress))
        #expect(container.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } == false)
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Select", "Select All",
        ])
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: true) == [
            "Select", "Select All", "Paste",
        ])
    }

    @Test("""
@spec IPAD-9.9: The `TerminalInputContainerView` in the active iPad terminal responder chain shall publish app-level Ghostty shortcuts as priority `UIKeyCommand`s for system arbitration and discoverability, and shall install itself as `UITerminalView`'s hardware-input delegate so the actual first responder dispatches the same enabled command candidates before Ghostty consumes raw presses. It shall publish priority correction commands only for Return, quote, Escape, and Tab, handle Ctrl-letter corrections through the delegate without adding 26 discoverability commands, synchronously request a UIKit menu-system rebuild whenever effective command metadata changes, and prefer an app-level shortcut on an exact chord collision. Every other unmatched terminal hardware key shall remain owned by `UITerminalView`.
""")
    func activeTerminalInputResponderRefreshesPublishedHardwareKeyboardCommands() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.keyCommands == nil)
        #expect(container.keyCommandUpdateRequestCountForTesting == 0)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
            .init(
                id: "next-worktree",
                title: "Next Worktree",
                input: "\t",
                modifierFlags: [.control],
                perform: {}
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        let publishedCommands = try! #require(container.keyCommands)
        #expect(publishedCommands.count == 2)
        #expect(publishedCommands[0].input == "d")
        #expect(publishedCommands[0].modifierFlags == [.command])
        #expect(publishedCommands[1].input == "\t")
        #expect(publishedCommands[1].modifierFlags == [.control])
        for command in publishedCommands {
            #expect(command.wantsPriorityOverSystemBehavior)
        }
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 2)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 3)
        #expect(container.keyCommands?.first?.input == "j")

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command, .shift],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 4)
        #expect(container.keyCommands?.first?.modifierFlags == [.command, .shift])

        container.hardwareKeyboardCommands = []
        #expect(container.keyCommandUpdateRequestCountForTesting == 5)
        #expect(container.keyCommands == nil)
    }

    @Test("""
@spec IOS-6.19: While an owner terminal pane is the eligible iPad hardware-keyboard target, `UITerminalView` shall offer each physical press to Graftty's hardware-input delegate before Ghostty translation. The delegate shall intercept enabled app commands plus unmodified Return, unmodified apostrophe, Shift-apostrophe, unmodified Escape, unmodified Tab, and Ctrl+A through Ctrl+Z, using logical UIKit characters ahead of suspect HID usage. It shall forward the exact terminal text or ASCII control byte for each correction. An app-level shortcut shall win an exact chord collision. Shift-Return and every other unmatched hardware key shall return to `UITerminalView`, and an ineligible pane shall expose no transport corrections.
""")
    func terminalHardwareCorrectionsForwardExactTextOnlyWhileEligible() {
        let container = TerminalInputContainerView(frame: .zero)
        var texts: [String] = []
        var controlBytes: [UInt8] = []

        #expect(container.keyCommands == nil)
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            insertControlByte: { controlBytes.append($0) },
            deleteBackward: {}
        )

        let correctionCommands = try! #require(container.keyCommands)
        #expect(correctionCommands.count == 5)
        #expect(correctionCommands.map(\.input) == [
            "\r", "'", "'", UIKeyCommand.inputEscape, "\t",
        ])
        #expect(correctionCommands.map(\.modifierFlags) == [[], [], [.shift], [], []])
        #expect(correctionCommands.allSatisfy { $0.wantsPriorityOverSystemBehavior })

        // Model the crossed HID values seen on the physical iPad: logical
        // characters must win or apostrophe would still dispatch Return.
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x34,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x28,
                characters: "'",
                charactersIgnoringModifiers: "'",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x28,
                characters: "\"",
                charactersIgnoringModifiers: "'",
                modifierFlags: [.shift]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue),
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                modifierFlags: []
            )
        ))
        // Shift-Return is intentionally not reserved: it must keep flowing to
        // Ghostty so bindings such as `shift+enter=text:\\n` remain effective.
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue),
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifierFlags: [.shift]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardA.rawValue),
                characters: "\u{1}",
                charactersIgnoringModifiers: "a",
                modifierFlags: [.control]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardJ.rawValue),
                characters: "\n",
                charactersIgnoringModifiers: "j",
                modifierFlags: [.control]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardZ.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: [.control]
            )
        ))
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardA.rawValue),
                characters: ";",
                charactersIgnoringModifiers: ";",
                modifierFlags: [.control]
            )
        ))
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])

        var appEscapeCount = 0
        var appControlXCount = 0
        container.hardwareKeyboardCommands = [
            .init(
                id: "app-escape",
                title: "App Escape",
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                perform: { appEscapeCount += 1 }
            ),
            .init(
                id: "app-control-x",
                title: "App Control X",
                input: "x",
                modifierFlags: [.control],
                perform: { appControlXCount += 1 }
            ),
        ]
        #expect(container.keyCommands?.count == 6)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: []
            )
        ))
        #expect(appEscapeCount == 1)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardX.rawValue),
                characters: "\u{18}",
                charactersIgnoringModifiers: "",
                modifierFlags: [.control]
            )
        ))
        #expect(appControlXCount == 1)
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])

        container.hardwareKeyboardCommands = []
        container.committedSoftwareInput = nil
        #expect(container.keyCommands == nil)
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x34,
                characters: "'",
                charactersIgnoringModifiers: "'",
                modifierFlags: []
            )
        ))
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])
    }

    @Test("the terminal first responder delegates application hardware chords before Ghostty")
    func terminalHardwareInputDelegateDispatchesApplicationChords() {
        let container = TerminalInputContainerView(frame: .zero)
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("split") }
            ),
            .init(
                id: "next-pane",
                title: "Next Pane",
                input: "\t",
                modifierFlags: [.control],
                perform: { performed.append("pane") }
            ),
        ]

        #expect((container.terminalView.hardwareInputDelegate as AnyObject?) === container)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardD.rawValue),
                characters: "D",
                charactersIgnoringModifiers: "D",
                modifierFlags: [.command, .numericPad]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue),
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                modifierFlags: [.control]
            )
        ))
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardD.rawValue),
                characters: "D",
                charactersIgnoringModifiers: "D",
                modifierFlags: [.command, .shift]
            )
        ))
        #expect(performed == ["split", "pane"])
    }

    @Test("equivalent hardware command signatures retain UIKit's table and replace dispatch closures")
    func equivalentHardwareCommandSignatureUsesReplacementClosureWithoutInvalidation() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command, .numericPad],
                perform: { performed.append("new") }
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        #expect(container.keyCommands?.first?.modifierFlags == [.command])
        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == ["new"])
    }

    @Test("changed hardware command titles request a menu rebuild")
    func changedHardwareCommandTitleRequestsMenuRebuild() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 2)
        #expect(container.keyCommands?.first?.title == "Split Pane Right")
        #expect(container.keyCommands?.first?.discoverabilityTitle == "Split Pane Right")
    }

    @Test("hardware command dispatch requires an exact normalized input and modifier match")
    func hardwareCommandDispatchUsesExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed = 0
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed += 1 }
            ),
        ]

        container.performHardwareKeyboardCommandForTesting(input: "D", modifierFlags: [.command])
        container.performHardwareKeyboardCommandForTesting(input: "d", modifierFlags: [.command, .shift])
        #expect(performed == 0)

        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == 1)
    }

    @Test("stale cached hardware commands are rejected while current commands remain dispatchable")
    func staleCachedHardwareCommandIsRejected() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: { performed.append("current") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        #expect(container.canPerformAction(commandAction, withSender: currentCommand))

        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["current"])
    }

    @Test("stale cached command identity is rejected when its chord is reused")
    func staleCachedHardwareCommandWithReusedChordIsRejected() {
        let container = TerminalInputContainerView(frame: .zero)
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("retitled") }
            ),
        ]
        let retitledCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(retitledCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        container.perform(commandAction, with: staleCommand)
        #expect(performed.isEmpty)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("new") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        #expect(!container.canPerformAction(commandAction, withSender: retitledCommand))
        container.perform(commandAction, with: retitledCommand)
        #expect(performed.isEmpty)

        #expect(container.canPerformAction(commandAction, withSender: currentCommand))
        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["new"])
    }

    @Test("hardware command validation rejects nil input and mismatched modifiers")
    func hardwareCommandValidationRequiresExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)
        let nilInputCommand = NilInputKeyCommand(
            title: "Missing Input",
            action: commandAction,
            input: "j",
            modifierFlags: [.command]
        )
        let mismatchedModifierCommand = UIKeyCommand(
            title: "Wrong Modifiers",
            action: commandAction,
            input: "j",
            modifierFlags: [.command, .shift]
        )

        #expect(!container.canPerformAction(commandAction, withSender: nilInputCommand))
        #expect(!container.canPerformAction(commandAction, withSender: mismatchedModifierCommand))
    }

    @Test("ordinary reconstructed key commands validate stable identity and title")
    func reconstructedHardwareCommandValidatesStableIdentityAndTitle() {
        let container = TerminalInputContainerView(frame: .zero)
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let action = try! #require(container.keyCommands?.first?.action)

        let matching = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleID = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-right",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleTitle = UIKeyCommand(
            title: "Split Right",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Right",
            attributes: [],
            state: .off
        )

        #expect(container.canPerformAction(action, withSender: matching))
        #expect(!container.canPerformAction(action, withSender: staleID))
        #expect(!container.canPerformAction(action, withSender: staleTitle))
    }

    @Test("hardware command changes do not alter unrelated action validation")
    func unrelatedActionValidationIsUnchanged() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let action = #selector(UIResponderStandardEditActions.copy(_:))
        let resultBeforeCommand = container.canPerformAction(action, withSender: nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(container.canPerformAction(action, withSender: nil) == resultBeforeCommand)
    }

    @Test("keyCommands are cached between queries and invalidated on signature change")
    func keyCommandsAreCachedUntilSignatureChanges() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]

        // UIKit queries keyCommands on every hardware key-down; repeated
        // queries must return the cached objects, not fresh allocations.
        let first = container.keyCommands?.first
        let second = container.keyCommands?.first
        #expect(first != nil)
        #expect(first === second)

        // A signature-equal update (fresh closures, same chords) keeps the cache.
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]
        #expect(container.keyCommands?.first === first)

        // A real signature change rebuilds.
        container.hardwareKeyboardCommands = [
            .init(id: "split-down", title: "Split Down", input: "j", modifierFlags: [.command], perform: {}),
        ]
        let rebuilt = container.keyCommands?.first
        #expect(rebuilt !== first)
        #expect(rebuilt?.input == "j")
    }

    @Test("selection mode keeps indirect terminal pan recognizers enabled")
    func selectionModeKeepsIndirectScrollingEnabled() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        container.enterSelectionModeForTesting()

        let pans = container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty)
        #expect(pans.allSatisfy { $0.isEnabled })
    }

    @Test("""
@spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and the active terminal or checkpoint-canvas scroll recognizers shall stop receiving direct touches (indirect trackpad/mouse scrolling stays enabled) until selection mode exits.
""")
    func selectionModeStripsDirectTouchesFromScrollPans() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let maskedPans = {
            (container.terminalView.gestureRecognizers ?? [])
                .compactMap { $0 as? UIPanGestureRecognizer }
                .filter { !$0.allowedScrollTypesMask.isEmpty }
        }
        let savedTouchTypes = maskedPans().map(\.allowedTouchTypes)
        #expect(!maskedPans().isEmpty)

        container.enterSelectionModeForTesting()
        // allowedScrollTypesMask only adds indirect scroll recognition; the
        // direct-touch block must come from narrowing allowedTouchTypes.
        #expect(maskedPans().allSatisfy {
            $0.allowedTouchTypes == TerminalInputContainerView.indirectPointerOnlyTouchTypes
        })

        container.exitSelectionModeForTesting()
        #expect(maskedPans().map(\.allowedTouchTypes) == savedTouchTypes)
    }

    @Test("focus requests require an eligible terminal owned by the requesting attachment")
    func focusRequestNotConsumedUntilTerminalCanFocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let coordinator = TerminalPaneView.Coordinator()
        container.controlAttachmentID = coordinator.controlAttachmentID
        var consumedCount = 0
        coordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        container.committedSoftwareInput = nil

        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 0)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 1)
        #expect(container.terminalView.isFirstResponder)

        container.terminalView.resignFirstResponder()
        coordinator.applyFocusRequest(1, to: container)
        container.controlAttachmentID = UUID()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 1)
        #expect(!container.terminalView.isFirstResponder)
    }

    @Test("""
@spec IPAD-8.9: When a terminal pane remounts with zero pending focus requests (all prior requests already honored and consumed), the application shall not call becomeFirstResponder, so a keyboard the user dismissed is not re-summoned by idle-snapshot swaps or other view recreations.
""")
    func remountWithNoPendingFocusRequestsDoesNotSummonKeyboard() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Keyboard-eligible: a stale-total replay would succeed if attempted.
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        // A remount creates a fresh Coordinator with no memory; the counter
        // owners survive the remount and report zero pending requests.
        let freshCoordinator = TerminalPaneView.Coordinator()
        container.controlAttachmentID = freshCoordinator.controlAttachmentID
        var consumedCount = 0
        freshCoordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        freshCoordinator.applyFocusRequest(0, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(consumedCount == 0)
        #expect(!container.terminalView.isFirstResponder)
    }

    @Test("""
@spec IOS-11.12: When the user taps Paste from the terminal long-press edit menu, the application shall forward the clipboard paste request and re-focus the eligible `UITerminalView` after UIKit's edit-menu dismissal completes, so the dismissal cannot subsequently resign the terminal and leave the user without keyboard control.
""")
    func pasteMenuRefocusesEligibleTerminalAfterDismissalCompletes() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        let animator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: animator)
        // UIKit is allowed to begin dismissal before invoking the selected
        // action. Register the completion first to cover that ordering.
        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(!container.terminalView.isFirstResponder)

        animator.finish()

        // The refocus deliberately leaves UIKit's dismissal-completion turn.
        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("Paste refocuses when edit-menu dismissal completes before the action callback")
    func pasteMenuRefocusesWhenDismissalCompletesBeforeAction() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        let animator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: animator)
        animator.finish()
        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("selection-menu dismissal cannot consume a pending Paste refocus")
    func selectionMenuDismissalDoesNotConsumePendingPasteRefocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        container.performPasteForTesting()
        let selectionAnimator = DeferredEditMenuAnimator()
        container.dismissSelectionMenuForTesting(animator: selectionAnimator)
        selectionAnimator.finish()

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(!container.terminalView.isFirstResponder)

        let longPressAnimator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: longPressAnimator)
        longPressAnimator.finish()

        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("any touch on the terminal container fires onUserInteraction")
    func touchBeganFiresUserInteraction() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var fired = 0
        container.onUserInteraction = { fired += 1 }

        container.simulateAnyTouchBeganForTesting()

        #expect(fired == 1)
    }

    @Test("""
@spec IOS-6.6: While an owner terminal pane is focused on iOS, committed software-keyboard text and delete shall flow through `UITerminalView`'s supported `TerminalSoftwareInputDelegate` and be forwarded exactly once to `SessionClient.sendSoftwareKeyboardText(_:)` and `deleteBackward()`. A single software-keyboard newline shall be translated to CR (`0x0D`) per `IOS-6.3`, and delete shall send DEL (`0x7F`), without using Ghostty's paste-text path.
""")
    func committedSoftwareInputDelegateForwardsExactlyOnce() {
        let container = TerminalInputContainerView(frame: .zero)
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        #expect(container.terminalView.softwareInputDelegate === container)
        container.terminalView.insertText("hello")
        container.terminalView.deleteBackward()
        #expect(texts == ["hello"])
        #expect(deletes == 1)
    }

    @Test("ineligible terminal consumes pending committed input after owner loss")
    func ownerLossConsumesPendingCommittedInputWithoutForwarding() {
        let container = TerminalInputContainerView(frame: .zero)
        let delegate: any TerminalSoftwareInputDelegate = container
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        container.committedSoftwareInput = nil

        #expect(delegate.terminalView(container.terminalView, insertText: "pending"))
        #expect(delegate.terminalViewDeleteBackward(container.terminalView))
        #expect(texts.isEmpty)
        #expect(deletes == 0)
        #expect(!container.terminalView.isKeyboardInputEnabled)
    }

    @Test("""
@spec IOS-6.2: `UITerminalView` shall be the sole terminal keyboard responder and the primary owner of rendering and hardware-key event translation for every iOS pane. Before Ghostty translation it may delegate enabled application commands, the listed transport corrections in `IOS-6.19`, and active agent completion in `IOS-6.32`; every unmatched key, including arrows, shall flow through libghostty, and GrafttyMobile shall not reimplement general terminal key translation.
""")
    func eligibleTerminalBecomesFirstResponderInWindow() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        #expect(container.terminalView.becomeFirstResponder())
        #expect(container.terminalView.isFirstResponder)
        #expect(container.terminalView.next === container.snapshotScrollView)
        #expect(container.snapshotScrollView.next === container)

        container.committedSoftwareInput = nil
        #expect(!container.terminalView.isFirstResponder)
        #expect(!container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.18: When a hardware press does not match an enabled application command, a Return/quote/Escape/Tab/Ctrl-letter correction in `IOS-6.19`, or active agent completion in `IOS-6.32`, the sole `UITerminalView` responder shall pass it to libghostty's hardware-key translation. GrafttyMobile shall not install any other per-key handlers; explicit control-bar Escape shall use active agent completion under `IOS-6.34` or otherwise remain a `SessionClient.sendEscape()` command under `IOS-6.1`.
""")
    func containerPublishesNoGeneralTerminalKeyCommands() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(container.keyCommands == nil)
    }
}

@MainActor
private final class TouchScrollPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .changed
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: 30) }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) {}
}

private final class ScrollInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    func contains(_ text: String) -> Bool {
        lock.withLock { bytes.range(of: Data(text.utf8)) != nil }
    }
    var description: String { lock.withLock { String(decoding: bytes, as: UTF8.self).debugDescription } }
}

private final class PhysicalViewportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var viewports: [InMemoryTerminalViewport] = []
    func append(_ viewport: InMemoryTerminalViewport) { lock.withLock { viewports.append(viewport) } }
    func snapshot() -> [InMemoryTerminalViewport] { lock.withLock { viewports } }
}

@Suite(.serialized)
@MainActor
struct PagedSourceGridTests {
    @Test("@spec IOS-4.49: When an owning mobile pane receives an in-band source grid, the application shall update the parser without fitting the physical viewport to that grid, while continuing to report keyboard, rotation, and font size changes.", .enabled(if: MobilePagedTerminalRenderer.isSupported))
    func sourceGridAcknowledgementKeepsOwnerViewportStable() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let responses = TerminalResponseRecorder()
        let viewports = PhysicalViewportRecorder()
        let session = InMemoryTerminalSession(write: { responses.append($0) }, resize: { viewports.append($0) })
        container.terminalView.configuration = .init(backend: .inMemory(session))
        // Resize callbacks report content pixels; view metrics include padding.
        // Remove fixture padding so their pixel dimensions must match exactly.
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: """
        font-size = 14
        window-padding-x = 0
        window-padding-y = 0
        window-padding-balance = false
        """)
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer { container.removeFromSuperview(); window.isHidden = true }
        var previousViewport = try await waitForPhysicalViewport(container, recordedBy: viewports, after: 0, stage: "initial mount")
        // Let the initial mounting callbacks settle before measuring whether
        // source acknowledgements themselves generate another physical resize.
        try await Task.sleep(for: .milliseconds(100))
        let initialResizeCount = viewports.snapshot().count
        let original = container.terminalView.bounds
        var preparedGrids = 0
        let renderer = MobilePagedTerminalRenderer(session: session) { cols, rows in
            preparedGrids += 1
            container.authoritativeGrid = .init(cols: cols, rows: rows)
            container.layoutIfNeeded()
        }
        // An acknowledgement can describe an earlier viewport while the keyboard
        // or rotation has already changed the physical one. It must not refit it.
        for _ in 0..<4 {
            try await renderer.setSourceGrid(cols: 80, rows: 24)
            #expect(container.authoritativeGrid == nil)
            #expect(container.terminalView.bounds == original)
        }
        #expect(preparedGrids == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewports.snapshot().count == initialResizeCount,
                "Source-grid acknowledgements must not generate physical resize callbacks")
        await expectParserGrid(session, responses: responses, cols: 80, rows: 24)
        for size in [CGSize(width: 390, height: 350), CGSize(width: 700, height: 390)] {
            let beforeResize = viewports.snapshot().count
            container.frame.size = size
            container.layoutIfNeeded()
            let viewport = try await waitForPhysicalViewport(container, recordedBy: viewports,
                after: beforeResize, differingFrom: previousViewport, stage: "physical bounds \(size)")
            #expect(viewport.columns != previousViewport.columns || viewport.rows != previousViewport.rows,
                    "Keyboard and rotation geometry must report a changed physical grid")
            previousViewport = viewport
            #expect(container.terminalView.bounds.size == size)
            await expectParserGrid(session, responses: responses, cols: 80, rows: 24)
        }
        let beforeFontResize = viewports.snapshot().count
        #expect(container.terminalView.surface?.performBindingAction("increase_font_size:1") == true)
        let fontViewport = try await waitForPhysicalViewport(container, recordedBy: viewports,
            after: beforeFontResize, differingFrom: previousViewport, stage: "font change")
        #expect(fontViewport.columns != previousViewport.columns || fontViewport.rows != previousViewport.rows,
                "Font changes must report a changed physical grid while the parser is pinned")
        await expectParserGrid(session, responses: responses, cols: 80, rows: 24)
        let physical = try #require(container.terminalGridMetrics)
        let beforeAcknowledgement = viewports.snapshot().count
        try await renderer.setSourceGrid(cols: physical.columns, rows: physical.rows)
        await expectParserGrid(session, responses: responses, cols: physical.columns, rows: physical.rows)
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewports.snapshot().count == beforeAcknowledgement,
                "Acknowledging the changed physical grid must not trigger another resize")
        try await renderer.releaseSourceGrid()
    }

    @Test("@spec IOS-4.47: While a mobile terminal consumes a paged source stream, the application shall preserve the source parser grid across local viewport and font changes until the next in-band source grid is applied.", .enabled(if: MobilePagedTerminalRenderer.isSupported))
    func sourceParserGridSurvivesPhysicalResizeAndFontChanges() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        container.layoutIfNeeded()
        let responses = TerminalResponseRecorder()
        let session = InMemoryTerminalSession(write: { responses.append($0) }, resize: { _ in })
        let controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = controller
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer { container.removeFromSuperview(); window.isHidden = true }
        let grid = try #require(container.terminalGridMetrics)
        let renderer = MobilePagedTerminalRenderer(session: session) { cols, rows in
            container.authoritativeGrid = .init(cols: cols, rows: rows)
            container.layoutIfNeeded()
        }
        try await renderer.setSourceGrid(cols: grid.columns, rows: grid.rows)
        // Source-grid pinning no longer fits the view. Model the follower
        // presentation explicitly before exercising its release on takeover.
        container.authoritativeGrid = .init(cols: grid.columns, rows: grid.rows)
        container.layoutIfNeeded()
        #expect(container.authoritativeGrid != nil)
        // Ownership releases the fitted canvas; this also leaves a native
        // coalesced resize pending when a keyboard changes physical bounds.
        container.authoritativeGrid = nil
        container.frame.size = CGSize(width: 330, height: 400)
        container.layoutIfNeeded()
        for _ in 0..<100 where container.terminalGridMetrics?.heightPixels == grid.heightPixels {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(60))
        await expectParserGrid(session, responses: responses, cols: grid.columns, rows: grid.rows)
        session.receive("\u{1b}[\(grid.rows);1HOLD-GRID")
        await expectParserGrid(session, responses: responses, cols: grid.columns, rows: grid.rows)
        #expect(session.readViewportText()?.contains("OLD-GRID") == true)
        _ = container.terminalView.surface?.performBindingAction("increase_font_size:1")
        try await Task.sleep(for: .milliseconds(60))
        await expectParserGrid(session, responses: responses, cols: grid.columns, rows: grid.rows)
        // The next source event may now change parsing dimensions. A
        // previously queued local resize must not undo that ordered change.
        try await renderer.setSourceGrid(cols: 41, rows: 23)
        container.authoritativeGrid = nil
        container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        await expectParserGrid(session, responses: responses, cols: 41, rows: 23)
        session.receive("\u{1b}[23;1HNEW-GRID")
        await expectParserGrid(session, responses: responses, cols: 41, rows: 23)
        #expect(session.readViewportText()?.contains("NEW-GRID") == true)
        let physical = try #require(container.terminalGridMetrics)
        try await renderer.releaseSourceGrid()
        await expectParserGrid(session, responses: responses, cols: physical.columns, rows: physical.rows)
    }

    @Test("@spec IOS-4.48: When a paged source grid arrives before the mobile terminal surface mounts, the application shall wait for native readiness before completing the ordered grid operation.", .enabled(if: MobilePagedTerminalRenderer.isSupported))
    func sourceGridWaitsForFirstSurfaceMount() async throws {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        var container: TerminalInputContainerView?
        var prepared: SessionClient.GridSize?
        var started = false
        var completed = false
        let renderer = MobilePagedTerminalRenderer(session: session) { cols, rows in
            prepared = .init(cols: cols, rows: rows)
            container?.authoritativeGrid = prepared
            container?.layoutIfNeeded()
        }
        let pending = Task { @MainActor in
            started = true
            try await renderer.setSourceGrid(cols: 80, rows: 24)
            completed = true
        }
        defer { pending.cancel() }
        for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started)
        #expect(prepared == nil, "A source-grid pin must not ask layout to fit the physical viewport")
        #expect(!completed)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let mounted = TerminalInputContainerView(frame: window.bounds)
        container = mounted
        mounted.authoritativeGrid = prepared
        mounted.terminalView.configuration = .init(backend: .inMemory(session))
        mounted.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        host.view.addSubview(mounted)
        mounted.layoutIfNeeded()
        defer { mounted.removeFromSuperview(); window.isHidden = true }
        try await pending.value
        #expect(completed)
    }

    private func waitForPhysicalViewport(_ container: TerminalInputContainerView,
                                         recordedBy recorder: PhysicalViewportRecorder,
                                         after count: Int,
                                         differingFrom previous: InMemoryTerminalViewport? = nil,
                                         stage: String) async throws -> InMemoryTerminalViewport {
        var reported: InMemoryTerminalViewport?
        for _ in 0..<100 {
            let viewports = recorder.snapshot()
            if viewports.count > count, let viewport = viewports.last,
               previous == nil || viewport.columns != previous?.columns || viewport.rows != previous?.rows,
               let metrics = container.terminalGridMetrics,
               viewport.columns == metrics.columns, viewport.rows == metrics.rows,
               // The native resize callback carries grid and pixel dimensions.
               // Cell dimensions are optional and can remain zero; the view
               // obtains its cell metrics through a separate native callback.
               viewport.widthPixels == metrics.widthPixels, viewport.heightPixels == metrics.heightPixels {
                reported = viewport
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(reported, "No matching physical resize at \(stage); callbacks after \(count): \(recorder.snapshot().dropFirst(count)); metrics: \(String(describing: container.terminalGridMetrics)); bounds: \(container.terminalView.bounds)")
    }

    private func expectParserGrid(_ session: InMemoryTerminalSession, responses: TerminalResponseRecorder,
                                  cols: UInt16, rows: UInt16) async {
        responses.clear()
        session.receive("\u{1b}[999;999H\u{1b}[6n")
        let expected = "\u{1b}[\(rows);\(cols)R"
        for _ in 0..<100 where !responses.contains(expected) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(responses.contains(expected), "Parser must retain source grid \(cols)x\(rows); reply: \(String(decoding: responses.snapshot(), as: UTF8.self).debugDescription)")
    }

}

@Suite(.serialized)
@MainActor
struct TerminalTouchScrollTests {
    @Test("Follower application drag waits for its owner viewport and is discarded by replacement or newer input", arguments: ["ready", "replacement", "input"])
    func followerApplicationScrollWaitsForOwner(outcome: String) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        let input = ScrollInputRecorder()
        let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
        let renderer = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = renderer
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer {
            container.onApplicationScrollRequested = nil
            container.removeFromSuperview()
            window.isHidden = true
        }
        let grid = try #require(container.terminalGridMetrics)
        let ready = "\u{1b}[\(grid.rows);\(grid.columns)R"
        for _ in 0..<100 where !input.contains(ready) {
            session.receive("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(input.contains(ready))
        container.controlAttachmentID = UUID()
        container.authoritativeGrid = .init(cols: grid.columns, rows: grid.rows)
        container.layoutIfNeeded()
        var claims = 0
        container.onApplicationScrollRequested = { claims += 1 }
        #expect(claims == 0, "Passive follower attachment must not claim control")
        let pan = TouchScrollPan()
        pan.point = CGPoint(x: 60, y: 60)
        pan.phase = .began
        container.handleApplicationScroll(pan)
        pan.phase = .ended
        container.handleApplicationScroll(pan)
        #expect(claims == 1)
        #expect(!input.contains("\u{1b}[<64;"), "Follower drag must wait for ownership")
        if outcome == "replacement" { container.controlAttachmentID = UUID() }
        if outcome == "input" {
            container.committedSoftwareInput = .init(
                insertText: { input.append(Data($0.utf8)) }, deleteBackward: {})
            _ = container.terminalView(container.terminalView, insertText: "k")
            #expect(input.contains("k"))
        }
        container.authoritativeGrid = nil
        container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!input.contains("\u{1b}[<64;"), "Canvas release must wait for the physical viewport callback")
        container.onPhysicalViewportReady = { _ in }
        for _ in 0..<100 {
            container.layoutIfNeeded()
            if input.contains("\u{1b}[<64;") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(input.contains("\u{1b}[<64;") == (outcome == "ready"),
                "An ended drag must replay only into its original, ready attachment: \(input.description)")
    }

    @Test("@spec IOS-6.26: When a user begins a scroll drag in an interactive mobile terminal, the application shall place the terminal pointer at the gesture location before sending wheel input so fullscreen applications receive scrolling in the touched region.")
    func fullscreenWheelUsesTouchedRegion() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        container.layoutIfNeeded()
        let input = ScrollInputRecorder()
        let session = InMemoryTerminalSession(write: { input.append($0) }, resize: { _ in })
        let renderer = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = renderer
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer {
            container.removeFromSuperview()
            window.isHidden = true
        }
        let grid = try #require(container.terminalGridMetrics)
        let ready = "\u{1b}[\(grid.rows);\(grid.columns)R"
        for _ in 0..<100 where !input.contains(ready) {
            session.receive("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(input.contains(ready))
        let pan = TouchScrollPan()
        let scale = container.terminalView.contentScaleFactor
        pan.point = CGPoint(x: CGFloat(grid.cellWidthPixels) * 8.5 / scale,
                            y: CGFloat(grid.cellHeightPixels) * 6.5 / scale)
        let nativePan = try #require(container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let delegate = try #require(nativePan.delegate)
        #expect(delegate === container.terminalView)
        #expect(delegate.gestureRecognizerShouldBegin?(pan) == true)
        container.terminalView.handleTouchScrollGesture(pan)
        let wheelAtFinger = "\u{1b}[<64;9;7M"
        for _ in 0..<100 where !input.contains(wheelAtFinger) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(input.contains(wheelAtFinger), "Wheel input must target the touched cell: \(input.description)")
    }
}
#endif

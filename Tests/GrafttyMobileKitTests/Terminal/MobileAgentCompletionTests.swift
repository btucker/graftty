#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite
@MainActor
struct MobileAgentCompletionTests {
    private func setup() -> (TerminalInputContainerView, AgentCompletionModel, CompletionOutput) {
        let output = CompletionOutput()
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(
            insertText: { output.texts.append($0) },
            deleteBackward: { output.deletes += 1 }
        )
        let model = AgentCompletionModel()
        model.loadCandidates = { [Self.candidate] }
        container.agentCompletion = model
        return (container, model, output)
    }

    private static var candidate: AgentCompletionCandidate {
        .init(address: "/project/main#codex", projectPath: "/project", projectName: "Project",
              worktreePath: "/project/main", worktreeName: "main", hostName: "Mac", runtime: "codex")
    }

    private func key(_ usage: UIKeyboardHIDUsage, text: String = "",
                     modifiers: UIKeyModifierFlags = []) -> TerminalHardwareKeyEvent {
        .init(usage: UInt16(usage.rawValue), characters: text,
              charactersIgnoringModifiers: text, modifierFlags: modifiers)
    }

    @Test func focusTapPreservesPercentActivationWhilePointerTapInvalidatesIt() {
        let (container, model, output) = setup()
        container.simulateAnyTouchBeganForTesting()
        container.terminalView.insertText("%")
        #expect(model.isActive)
        #expect(output.texts.isEmpty)
        container.terminalView.insertText("pending")
        container.simulateAnyTouchBeganForTesting()
        #expect(!model.isActive)
        #expect(output.texts == ["%pending"])
        model.cancel(preserveLiteral: false)
        container.simulateAnyTouchBeganForTesting(changesCursor: true)
        container.terminalView.insertText("%")
        #expect(!model.isActive)
        #expect(output.texts.last == "%")
    }

    @Test func standaloneShiftPreservesPercentAndUppercaseQuery() {
        let (container, model, output) = setup()
        #expect(!container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardLeftShift, modifiers: .shift)))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboard5, text: "%", modifiers: .shift)))
        #expect(model.isActive)
        #expect(!container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardRightShift, modifiers: .shift)))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardM, text: "M", modifiers: .shift)))
        #expect(model.query == "M")
        #expect(output.texts.isEmpty)
    }

    @Test("@spec IOS-6.37: When an active iOS agent picker is interrupted by a transient inactive scene while its owned terminal transport remains live, the application shall preserve the literal token before closing the picker; when the application backgrounds or its transport becomes unavailable, the application shall discard the buffered token.", arguments: [ScenePhase.inactive, .background], [true, false])
    func sceneInterruption(_ phase: ScenePhase, _ transportIsAvailable: Bool) {
        let (container, model, output) = setup()
        container.terminalView.insertText("%")
        container.terminalView.insertText("pending")
        SingleSessionView.handleAgentCompletionSceneChange(
            phase, model: model, transportIsAvailable: transportIsAvailable
        )
        #expect(!model.isActive)
        #expect(output.texts == (phase == .inactive && transportIsAvailable ? ["%pending"] : []))
    }

    @Test("@spec IOS-6.36: When UIKit offers a software-input callback for a hardware key already consumed by iOS agent completion, the application shall suppress that callback so the token and accepted address are processed exactly once.")
    func hardwareUIKitEchoDoesNotEditTheLocalTokenTwice() {
        let (container, model, output) = setup()
        let percent = CompletionPress("%", usage: .keyboard5, modifiers: .shift)
        container.terminalView.pressesBegan([percent], with: nil)
        container.terminalView.insertText("%")
        #expect(model.isActive)
        #expect(model.query.isEmpty)
        #expect(output.texts.isEmpty)
        container.terminalView.pressesEnded([percent], with: nil)
        let letter = CompletionPress("m", usage: .keyboardM)
        container.terminalView.pressesBegan([letter], with: nil)
        container.terminalView.insertText("m")
        #expect(model.query == "m")
        #expect(output.texts.isEmpty)
        container.terminalView.pressesEnded([letter], with: nil)
    }

    @Test func tappedCandidateUsesTheOriginalTransportOnce() async {
        let (container, model, output) = setup()
        container.terminalView.insertText("%")
        await model.waitForLoad()
        model.accept(Self.candidate.id)
        #expect(output.texts == [Self.candidate.address])
        #expect(output.deletes == 0)
        #expect(!model.isActive)
    }

    @Test func heldPickerArrowStopsWhenCompletionCloses() async throws {
        let (container, model, _) = setup()
        container.terminalView.insertText("%")
        await model.waitForLoad()
        let down = CompletionPress(UIKeyCommand.inputDownArrow, usage: .keyboardDownArrow)
        container.terminalView.pressesBegan([down], with: nil)
        model.accept(Self.candidate.id)
        var forwardedArrows = 0
        container.hardwareKeyboardCommands = [.init(
            id: "arrow", title: "Arrow", input: UIKeyCommand.inputDownArrow, modifierFlags: [],
            perform: { forwardedArrows += 1 }
        )]
        try await Task.sleep(for: .milliseconds(550))
        #expect(forwardedArrows == 0)
        container.terminalView.pressesEnded([down], with: nil)
    }

    @Test func loadingOrEmptyPickerCannotSubmit() async {
        let (container, model, output) = setup()
        model.loadCandidates = { [] }
        container.terminalView.insertText("%")
        container.terminalView.insertText("\n")
        #expect(model.isActive)
        #expect(output.texts.isEmpty)
        await model.waitForLoad()
        container.terminalView.insertText("\t")
        #expect(model.isActive)
        #expect(output.texts.isEmpty)
    }

    @Test func applicationShortcutWinsAndFlushesLiteralFirst() {
        let (container, model, output) = setup()
        container.hardwareKeyboardCommands = [.init(
            id: "app-escape", title: "Escape", input: UIKeyCommand.inputEscape, modifierFlags: [],
            perform: { output.texts.append("app-command") }
        )]
        container.terminalView.insertText("%")
        container.terminalView.insertText("literal")
        #expect(container.terminalView(container.terminalView, handleHardwareKey: key(.keyboardEscape)))
        #expect(output.texts == ["%literal", "app-command"])
        #expect(!model.isActive)
    }

    @Test("@spec IOS-6.31: When committed iOS terminal input starts a percent agent token, the application shall buffer and edit the token locally, filter the native picker, and accept software Return or Tab without sending a submit byte or deleting remote text.", arguments: ["\n", "\t"])
    func softwareCompletion(_ accept: String) async {
        let (container, model, output) = setup()
        container.terminalView.insertText("hello ")
        container.terminalView.insertText("%")
        container.terminalView.insertText("maix")
        container.terminalView.deleteBackward()
        #expect(model.isActive)
        #expect(model.query == "mai")
        #expect(output.texts == ["hello "])
        #expect(output.deletes == 0)
        #expect(container.terminalView.offset(from: container.terminalView.beginningOfDocument,
                                            to: container.terminalView.endOfDocument) == 0)
        await model.waitForLoad()
        container.terminalView.insertText(accept)
        #expect(!model.isActive)
        #expect(output.texts == ["hello ", Self.candidate.address])
        #expect(output.deletes == 0)
    }

    @Test("@spec IOS-6.32: While an iOS agent picker is active, the application shall consume unmodified hardware arrows, Backspace, Return, Tab and Escape before terminal translation; modified keys and application shortcuts shall preserve their existing behavior.")
    func hardwareCompletion() async {
        let (container, model, output) = setup()
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboard5, text: "%", modifiers: .shift)))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardM, text: "m")))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardDeleteOrBackspace)))
        await model.waitForLoad()
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardDownArrow)))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardUpArrow)))
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardReturnOrEnter, text: "\r")))
        #expect(output.texts == [Self.candidate.address])
        #expect(output.deletes == 0)
        #expect(!model.isActive)

        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("literal")
        #expect(container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardEscape)))
        #expect(output.texts.last == "%literal")
        #expect(!model.isActive)
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("pending")
        #expect(!container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboardReturnOrEnter, text: "\r", modifiers: .shift)))
        #expect(output.texts.last == "%pending")
        #expect(!model.isActive)
        #expect(!container.terminalView(container.terminalView,
            handleHardwareKey: key(.keyboard5, text: "%", modifiers: .alternate)))
        #expect(!model.isActive)
    }

    @Test("@spec IOS-6.33: When iOS terminal composition, sticky Control, keyboard focus loss, or keyboard hiding interrupts agent completion while the original transport remains available, the application shall close the picker and preserve its literal token on the original input transport; marked text shall never open the picker.")
    func compositionAndFocus() {
        let (container, model, output) = setup()
        container.terminalView.setMarkedText("%marked", selectedRange: .init(location: 7, length: 0))
        container.terminalView.insertText("%marked")
        #expect(!model.isActive)
        #expect(output.texts == ["%marked"])
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("pending")
        container.terminalView.setMarkedText("word", selectedRange: .init(location: 4, length: 0))
        #expect(!model.isActive)
        #expect(output.texts.last == "%pending")
        container.terminalView.insertText("word")
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("focus")
        container.terminalView.resignFirstResponder()
        #expect(!model.isActive)
        #expect(output.texts.last == "%focus")
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("disabled")
        container.committedSoftwareInput = nil
        #expect(!model.isActive)
        #expect(output.texts.last == "%disabled")
        container.terminalView.insertText("%ignored")
        #expect(!model.isActive)
        #expect(output.deletes == 0)
    }

    @Test func stickyControlClosesCompletionBeforeTheNextInput() {
        let (container, model, output) = setup()
        container.terminalView.insertText("%")
        container.terminalView.insertText("literal")
        container.toggleStickyControlModifier()
        #expect(output.texts == ["%literal"])
        #expect(!model.isActive)
    }

    @Test("@spec IOS-6.34: While an iOS agent picker is active, the application shall route unmodified tray arrows, Return, Tab and Escape to completion and flush its literal token before other explicit terminal controls.")
    func trayCompletion() async {
        let (container, model, output) = setup()
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("main")
        await model.waitForLoad()
        #expect(container.handleAgentCompletionControl(.up))
        #expect(container.handleAgentCompletionControl(.down))
        #expect(container.handleAgentCompletionControl(.accept))
        #expect(output.texts == [Self.candidate.address])
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("literal")
        #expect(container.handleAgentCompletionControl(.escape))
        #expect(output.texts.last == "%literal")
        #expect(!model.isActive)
        model.cancel(preserveLiteral: false)
        container.terminalView.insertText("%")
        container.terminalView.insertText("shift")
        container.toggleTrayShift()
        #expect(!container.handleAgentCompletionControl(.accept))
        #expect(output.texts.last == "%shift")
        #expect(!model.isActive)
    }
}

@MainActor
private final class CompletionOutput {
    var texts: [String] = []
    var deletes = 0
}

private final class CompletionPress: UIPress {
    private let completionKey: CompletionKey
    init(_ text: String, usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags = []) {
        completionKey = CompletionKey(text, usage: usage, modifiers: modifiers)
        super.init()
    }
    override var key: UIKey? { completionKey }
}

private final class CompletionKey: UIKey {
    private let text: String
    private let usage: UIKeyboardHIDUsage
    private let modifiers: UIKeyModifierFlags
    init(_ text: String, usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) {
        self.text = text
        self.usage = usage
        self.modifiers = modifiers
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("CompletionKey is a test key") }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var characters: String { text }
    override var charactersIgnoringModifiers: String { text }
    override var modifierFlags: UIKeyModifierFlags { modifiers }
}
#endif

#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

extension TerminalInputContainerView {
    private struct HardwareKeyboardCommandSignature: Equatable {
        let id: String
        let title: String
        let input: String
        let modifierFlags: UIKeyModifierFlags
    }

    private struct TerminalHardwareTextCommand {
        let id: String
        let title: String
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let text: String
    }

    /// libghostty-spm's iPad hardware path currently loses Escape and crosses
    /// Return with the quote key: Return does not emit CR, while quote emits CR
    /// instead of its printable character; Tab can also be consumed by UIKit's
    /// focus traversal before Ghostty receives it. Reserve only those logical
    /// UIKit chords and feed their exact terminal text through the same
    /// committed-input transport as the software keyboard. Ctrl+A through
    /// Ctrl+Z are handled separately by `hardwareControlByte(for:)` below.
    /// Shift+Return deliberately remains with Ghostty so user bindings such
    /// as `shift+enter=text:\\n` keep working.
    private static let terminalHardwareTextCommands = [
        TerminalHardwareTextCommand(
            id: "terminal-return",
            title: "Terminal Return",
            input: "\r",
            modifierFlags: [],
            text: "\r"
        ),
        TerminalHardwareTextCommand(
            id: "terminal-apostrophe",
            title: "Terminal Apostrophe",
            input: "'",
            modifierFlags: [],
            text: "'"
        ),
        TerminalHardwareTextCommand(
            id: "terminal-double-quote",
            title: "Terminal Double Quote",
            input: "'",
            modifierFlags: [.shift],
            text: "\""
        ),
        TerminalHardwareTextCommand(
            id: "terminal-escape",
            title: "Terminal Escape",
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            text: "\u{1B}"
        ),
        TerminalHardwareTextCommand(
            id: "terminal-tab",
            title: "Terminal Tab",
            input: "\t",
            modifierFlags: [],
            text: "\t"
        ),
    ]

    public var hardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
        get { storedHardwareKeyboardCommands }
        set {
            let previousSignature = effectiveHardwareKeyboardCommandSignature
            storedHardwareKeyboardCommands = newValue
            guard previousSignature != effectiveHardwareKeyboardCommandSignature else { return }
            cachedKeyCommands = nil
            keyCommandUpdateRequestCountForTesting += 1
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    private var effectiveHardwareKeyboardCommandSignature: [HardwareKeyboardCommandSignature] {
        hardwareKeyboardCommands.map {
            HardwareKeyboardCommandSignature(
                id: $0.id,
                title: $0.title,
                input: $0.input,
                modifierFlags: $0.modifierFlags.appCommandModifiers
            )
        }
    }

    var effectiveHardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
        guard isCommittedSoftwareInputEligible else { return hardwareKeyboardCommands }
        let availableTransportCommands = Self.terminalHardwareTextCommands.filter { command in
            !hardwareKeyboardCommands.contains {
                $0.input == command.input
                    && $0.modifierFlags.appCommandModifiers
                        == command.modifierFlags.appCommandModifiers
            }
        }
        return hardwareKeyboardCommands + availableTransportCommands.map { command in
            TerminalPaneView.HardwareKeyboardCommand(
                id: command.id,
                title: command.title,
                input: command.input,
                modifierFlags: command.modifierFlags,
                perform: { [weak self] in
                    guard let self, self.isCommittedSoftwareInputEligible else { return }
                    if command.modifierFlags.isEmpty,
                       self.terminalView.handleAgentCompletionText(command.text) { return }
                    self.terminalView.commitAndResetTextContext()
                    self.storedCommittedSoftwareInput?.insertText(command.text)
                }
            )
        }
    }

    public func terminalView(
        _: UITerminalView,
        handleHardwareKey event: TerminalHardwareKeyEvent
    ) -> Bool {
        let normalizedModifiers = event.modifierFlags.appCommandModifiers
        let inputs = hardwareCommandInputs(for: event)
        // Enabled application shortcuts retain priority over completion.
        if let command = hardwareKeyboardCommands.first(where: {
            $0.modifierFlags.appCommandModifiers == normalizedModifiers
                && inputs.contains(canonicalHardwareCommandInput($0.input))
        }) {
            cancelPendingApplicationScroll()
            agentCompletion?.invalidateBoundary()
            command.perform()
            return true
        }
        let isShiftModifierPress = event.usage == UInt16(UIKeyboardHIDUsage.keyboardLeftShift.rawValue)
            || event.usage == UInt16(UIKeyboardHIDUsage.keyboardRightShift.rawValue)
        if !isShiftModifierPress { cancelPendingApplicationScroll() }
        if isCommittedSoftwareInputEligible, terminalView.markedTextRange == nil, !isShiftModifierPress {
            if normalizedModifiers.isEmpty {
                let completionKey: AgentCompletionKey?
                if inputs.contains(UIKeyCommand.inputUpArrow) { completionKey = .up }
                else if inputs.contains(UIKeyCommand.inputDownArrow) { completionKey = .down }
                else if inputs.contains("\r") || inputs.contains("\t") { completionKey = .accept }
                else if inputs.contains(UIKeyCommand.inputEscape) { completionKey = .escape }
                else { completionKey = nil }
                if let completionKey, agentCompletion?.handleKey(completionKey) == true {
                    return terminalView.didHandleAgentCompletionHardwareInput()
                }
                if inputs.contains("\u{8}"), agentCompletion?.handleBackspace() == true {
                    return terminalView.didHandleAgentCompletionHardwareInput()
                }
            }
            let isPrintable = !event.characters.isEmpty && event.characters.unicodeScalars.allSatisfy {
                $0.properties.generalCategory != .control && $0.value < 0xF700
            }
            if normalizedModifiers.subtracting([.shift]).isEmpty, isPrintable {
                if terminalView.handleAgentCompletionText(event.characters) {
                    return terminalView.didHandleAgentCompletionHardwareInput()
                }
            } else {
                agentCompletion?.invalidateBoundary()
            }
        }
        guard let command = effectiveHardwareKeyboardCommands.first(where: {
            $0.modifierFlags.appCommandModifiers == normalizedModifiers
                && inputs.contains(canonicalHardwareCommandInput($0.input))
        }) else {
            guard isCommittedSoftwareInputEligible,
                  let byte = hardwareControlByte(for: event),
                  let committedInput = storedCommittedSoftwareInput
            else { return false }
            terminalView.resetTextContext(notifyingInputSystem: true)
            if let insertControlByte = committedInput.insertControlByte {
                insertControlByte(byte)
            } else {
                committedInput.insertText(String(UnicodeScalar(byte)))
            }
            return true
        }
        command.perform()
        return true
    }

    private func hardwareControlByte(for event: TerminalHardwareKeyEvent) -> UInt8? {
        guard event.modifierFlags.appCommandModifiers == [.control] else { return nil }

        let logicalInput = canonicalHardwareCommandInput(event.charactersIgnoringModifiers)
        if let byte = asciiControlByte(for: logicalInput) {
            return byte
        }

        guard logicalInput.isEmpty,
              let hardwareInput = hardwareLetterInput(for: event.usage)
        else { return nil }
        return asciiControlByte(for: hardwareInput)
    }

    private func hardwareLetterInput(for usage: UInt16) -> String? {
        let firstLetterUsage = UInt16(UIKeyboardHIDUsage.keyboardA.rawValue)
        let lastLetterUsage = UInt16(UIKeyboardHIDUsage.keyboardZ.rawValue)
        guard usage >= firstLetterUsage, usage <= lastLetterUsage else {
            return nil
        }
        let asciiLowercaseA: UInt16 = 0x61
        let ascii = asciiLowercaseA + usage - firstLetterUsage
        return String(UnicodeScalar(ascii)!)
    }

    private func asciiControlByte(for input: String) -> UInt8? {
        guard input.utf8.count == 1, let ascii = input.utf8.first,
              ascii >= 0x61, ascii <= 0x7A
        else { return nil }
        return ascii & 0x1F
    }

    private func hardwareCommandInputs(for event: TerminalHardwareKeyEvent) -> Set<String> {
        if !event.charactersIgnoringModifiers.isEmpty {
            return [canonicalHardwareCommandInput(event.charactersIgnoringModifiers)]
        }
        if let input = Self.hardwareCommandInputByUsage[event.usage] {
            return [input]
        }
        if let input = hardwareLetterInput(for: event.usage) {
            return [input]
        }
        return []
    }

    private func canonicalHardwareCommandInput(_ input: String) -> String {
        guard input.unicodeScalars.count == 1,
              let scalar = input.unicodeScalars.first,
              scalar.value >= 0x41,
              scalar.value <= 0x5A
        else {
            return input
        }
        return String(UnicodeScalar(scalar.value + 0x20)!)
    }

    private static let hardwareCommandInputByUsage: [UInt16: String] = [
        UInt16(UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue): "\r",
        UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue): UIKeyCommand.inputEscape,
        UInt16(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue): "\u{8}",
        UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue): "\t",
        UInt16(UIKeyboardHIDUsage.keyboardSpacebar.rawValue): " ",
        UInt16(UIKeyboardHIDUsage.keyboardHome.rawValue): UIKeyCommand.inputHome,
        UInt16(UIKeyboardHIDUsage.keyboardPageUp.rawValue): UIKeyCommand.inputPageUp,
        UInt16(UIKeyboardHIDUsage.keyboardDeleteForward.rawValue): UIKeyCommand.inputDelete,
        UInt16(UIKeyboardHIDUsage.keyboardEnd.rawValue): UIKeyCommand.inputEnd,
        UInt16(UIKeyboardHIDUsage.keyboardPageDown.rawValue): UIKeyCommand.inputPageDown,
        UInt16(UIKeyboardHIDUsage.keyboardRightArrow.rawValue): UIKeyCommand.inputRightArrow,
        UInt16(UIKeyboardHIDUsage.keyboardLeftArrow.rawValue): UIKeyCommand.inputLeftArrow,
        UInt16(UIKeyboardHIDUsage.keyboardDownArrow.rawValue): UIKeyCommand.inputDownArrow,
        UInt16(UIKeyboardHIDUsage.keyboardUpArrow.rawValue): UIKeyCommand.inputUpArrow,
    ]

    @objc func handleHardwareKeyboardCommand(_ command: UIKeyCommand) {
        guard let match = matchingHardwareKeyboardCommand(for: command) else { return }
        cancelPendingApplicationScroll()
        if hardwareKeyboardCommands.contains(where: { $0.id == match.id }) {
            agentCompletion?.invalidateBoundary()
        }
        match.perform()
    }

    func matchingHardwareKeyboardCommand(
        for keyCommand: UIKeyCommand
    ) -> TerminalPaneView.HardwareKeyboardCommand? {
        guard let commandID = keyCommand.propertyList as? String,
              let input = keyCommand.input else { return nil }
        let modifierFlags = keyCommand.modifierFlags.appCommandModifiers
        return effectiveHardwareKeyboardCommands.first {
            $0.id == commandID
                && $0.title == keyCommand.title
                && $0.input == input
                && $0.modifierFlags.appCommandModifiers == modifierFlags
        }
    }
}
#endif

//
//  TerminalHardwareInputDelegate.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    /// A logical UIKit hardware-key event offered to the embedding app before
    /// Ghostty translates it. Returning `true` consumes the complete press;
    /// the matching release is not delivered to Ghostty either.
    public struct TerminalHardwareKeyEvent {
        public let usage: UInt16
        public let characters: String
        public let charactersIgnoringModifiers: String
        public let modifierFlags: UIKeyModifierFlags

        public init(
            usage: UInt16,
            characters: String,
            charactersIgnoringModifiers: String,
            modifierFlags: UIKeyModifierFlags
        ) {
            self.usage = usage
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers
            self.modifierFlags = modifierFlags
        }
    }

    @MainActor
    public protocol TerminalHardwareInputDelegate: AnyObject {
        func terminalView(
            _ view: UITerminalView,
            handleHardwareKey event: TerminalHardwareKeyEvent
        ) -> Bool
    }
#endif

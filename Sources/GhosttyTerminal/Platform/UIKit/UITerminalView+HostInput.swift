#if canImport(UIKit)
    import UIKit

    extension UITerminalView {
        public var softwareInputDelegate: (any TerminalSoftwareInputDelegate)? {
            get { textInputBridge.softwareInputDelegate }
            set { textInputBridge.softwareInputDelegate = newValue }
        }

        public var hardwareInputDelegate: (any TerminalHardwareInputDelegate)? {
            get { hardwareKeyboard.inputDelegate }
            set { hardwareKeyboard.inputDelegate = newValue }
        }

        /// Disable when the host supplies its own hardware-key repeat timer.
        public var automaticallyRepeatsHardwareKeys: Bool {
            get { hardwareKeyboard.automaticallyRepeatsKeys }
            set {
                hardwareKeyboard.automaticallyRepeatsKeys = newValue
                if !newValue { stopKeyRepeat() }
            }
        }

        /// Hosts supplying their own retained UITextInput document can disable
        /// the synthetic position used to keep software-keyboard Delete repeating.
        /// Configure this before editing; the default is enabled on iOS.
        public var usesTextInputDocumentAnchor: Bool {
            get { textInputBridge.usesDocumentAnchor }
            set { textInputBridge.usesDocumentAnchor = newValue }
        }

        public var isKeyboardInputEnabled: Bool {
            get { textInputBridge.keyboardInputEnabled }
            set {
                textInputBridge.keyboardInputEnabled = newValue
                if !newValue {
                    stopKeyRepeat()
                    resignFirstResponder()
                }
            }
        }

        public var showsInputAccessory: Bool {
            get { textInputBridge.showsInputAccessory }
            set {
                guard textInputBridge.showsInputAccessory != newValue else { return }
                textInputBridge.showsInputAccessory = newValue
                reloadInputViews()
            }
        }

        @discardableResult
        func offerHardwareKey(_ event: TerminalHardwareKeyEvent) -> Bool {
            guard hardwareInputDelegate?.terminalView(self, handleHardwareKey: event) == true else { return false }
            return true
        }
    }
#endif

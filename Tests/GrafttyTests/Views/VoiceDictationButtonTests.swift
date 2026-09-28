import AppKit
import Testing
@testable import Graftty

@MainActor
struct VoiceDictationButtonTests {
    @Test("@spec KEY-4.6: While the collapsed sidebar displays a dictation hint, the application shall keep the microphone control and its callout from taking terminal keyboard focus.")
    func controlsDoNotTakeKeyboardFocus() {
        _ = NSApplication.shared
        let button = DictationMicrophoneButton(frame: .zero)
        let panel = DictationHintPanel()
        #expect(!button.acceptsFirstResponder)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
    }
}

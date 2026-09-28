import AppKit
import QuartzCore
import SwiftUI

/// @spec KEY-4.5: While voice dictation is listening, the application shall pulse the sidebar microphone and display a Send prompt hint inline in the expanded sidebar or beside the collapsed rail.
struct VoiceDictationButton: View {
    @ObservedObject var controller: VoiceDictationController
    let target: SurfaceHandle?
    let collapsed: Bool

    private var hint: String? {
        controller.errorMessage ?? (controller.isListening ? "Say \"Send prompt\" to send" : nil)
    }

    var body: some View {
        VStack(spacing: 3) {
            MicrophoneControl(
                isListening: controller.isListening,
                isEnabled: target != nil || controller.isListening,
                callout: collapsed ? hint : nil
            ) {
                controller.toggle(target: target)
            }
            .frame(width: 36, height: 36)
            if !collapsed, let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(controller.errorMessage == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct MicrophoneControl: NSViewRepresentable {
    let isListening: Bool
    let isEnabled: Bool
    let callout: String?
    let action: () -> Void

    func makeNSView(context: Context) -> DictationMicrophoneButton {
        DictationMicrophoneButton(frame: .zero)
    }

    func updateNSView(_ button: DictationMicrophoneButton, context: Context) {
        button.onClick = action
        button.isEnabled = isEnabled
        button.update(isListening: isListening, hint: callout)
    }

    static func dismantleNSView(_ button: DictationMicrophoneButton, coordinator: ()) {
        button.hideHint()
        button.onClick = nil
    }
}

/// A native button explicitly refuses first responder so clicking Stop cannot
/// end terminal composition through an unrelated focus transition.
final class DictationMicrophoneButton: NSButton {
    var onClick: (() -> Void)?
    private var hintText: String?
    private var hintPanel: DictationHintPanel?
    private var listening = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    func update(isListening: Bool, hint: String?) {
        image = NSImage(systemSymbolName: isListening ? "mic.fill" : "mic", accessibilityDescription: nil)
        contentTintColor = isListening ? .controlAccentColor : .secondaryLabelColor
        let label = isListening ? "Stop dictation" : "Start dictation"
        setAccessibilityLabel(label)
        toolTip = isEnabled ? label : "Select a terminal to dictate"
        if listening != isListening {
            listening = isListening
            layer?.removeAnimation(forKey: "dictationPulse")
            if isListening && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                layer?.add(pulse, forKey: "dictationPulse")
            }
        }
        if hintText != hint {
            hintText = hint
            hideHint()
        }
        showHintIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideHint()
        showHintIfNeeded()
    }

    override func layout() {
        super.layout()
        showHintIfNeeded()
    }

    func hideHint() {
        guard let hintPanel else { return }
        hintPanel.parent?.removeChildWindow(hintPanel)
        hintPanel.orderOut(nil)
        self.hintPanel = nil
    }

    private func showHintIfNeeded() {
        guard let hintText, let window, !isHiddenOrHasHiddenAncestor else {
            hideHint()
            return
        }
        let panel: DictationHintPanel
        if let hintPanel {
            panel = hintPanel
        } else {
            panel = DictationHintPanel()
            let content = NSHostingView(rootView:
                Text(hintText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 224)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            )
            panel.contentView = content
            panel.setContentSize(content.fittingSize)
            hintPanel = panel
            window.addChildWindow(panel, ordered: .above)
        }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        let x = min(anchor.maxX + 8, screen.maxX - panel.frame.width)
        let y = min(max(anchor.midY - panel.frame.height / 2, screen.minY), screen.maxY - panel.frame.height)
        panel.setFrameOrigin(NSPoint(x: max(screen.minX, x), y: y))
        panel.orderFront(nil)
    }
}

/// A child window instead of a SwiftUI popover keeps the terminal responder
/// active while exposing the hint outside the collapsed rail's clipped bounds.
final class DictationHintPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

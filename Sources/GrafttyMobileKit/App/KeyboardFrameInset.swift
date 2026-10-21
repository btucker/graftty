import CoreGraphics

enum KeyboardFrameInset {
    /// Vertical overlap (in points) between the keyboard's end frame
    /// (from `UIResponder.keyboardFrameEndUserInfoKey`) and the screen
    /// bounds. Returns 0 when the keyboard is fully off-screen — e.g.
    /// the `keyboardWillHide` snapshot, where the frame's `origin.y`
    /// equals the screen height.
    static func bottomInset(
        keyboardEndFrame: CGRect,
        screenBounds: CGRect
    ) -> CGFloat {
        let intersection = keyboardEndFrame.intersection(screenBounds)
        if intersection.isNull || intersection.isEmpty { return 0 }
        // Floating and split keyboards can intersect the screen without
        // occupying its bottom edge. Bottom padding cannot route around a
        // middle-of-screen rectangle; treating its full height as an inset
        // only shrinks the entire terminal tree for no benefit.
        guard keyboardEndFrame.maxY >= screenBounds.maxY else { return 0 }
        return intersection.height
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

extension KeyboardFrameInset {
    /// Bottom inset from a `keyboardWillChangeFrame` notification, or nil
    /// when the notification carries no end frame.
    static func bottomInset(for notification: Notification) -> CGFloat? {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return nil
        }
        return bottomInset(keyboardEndFrame: value.cgRectValue, screenBounds: UIScreen.main.bounds)
    }
}

/// One split tree's view of the keyboard, published by `MultiPaneDetailView`
/// so its embedded panes need no keyboard subscriptions of their own. The
/// sequence advances once per notification, letting panes react to repeated
/// notifications whose inset is unchanged.
struct KeyboardFrameObservation: Equatable {
    var bottomInset: CGFloat = 0
    var sequence: UInt64 = 0
}

extension View {
    /// Reports each keyboard frame notification's bottom inset. `isEnabled`
    /// must stay fixed for a view's lifetime: flipping it changes identity.
    @ViewBuilder
    func onKeyboardBottomInsetChange(isEnabled: Bool = true, perform: @escaping (CGFloat) -> Void) -> some View {
        if isEnabled {
            onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                if let inset = KeyboardFrameInset.bottomInset(for: $0) { perform(inset) }
            }
        } else {
            self
        }
    }
}

private struct MultiPaneKeyboardFrameKey: EnvironmentKey {
    static let defaultValue: KeyboardFrameObservation? = nil
}

extension EnvironmentValues {
    var multiPaneKeyboardFrame: KeyboardFrameObservation? {
        get { self[MultiPaneKeyboardFrameKey.self] }
        set { self[MultiPaneKeyboardFrameKey.self] = newValue }
    }
}
#endif

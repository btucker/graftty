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
        return intersection.height
    }
}

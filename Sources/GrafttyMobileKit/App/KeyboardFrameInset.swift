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

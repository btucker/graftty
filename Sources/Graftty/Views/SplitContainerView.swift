import SwiftUI
import GrafttyCommandUI
import GrafttyKit

/// A view that renders two children with a draggable divider.
struct SplitContainerView<Left: View, Right: View>: View {
    let direction: SplitDirection
    @Binding var ratio: Double
    let left: Left
    let right: Right
    /// Called once when the drag ends, with the final (clamped) ratio.
    /// Callers use this to persist the new ratio back into the owning
    /// `SplitTree` without rewriting the tree on every mouse event —
    /// which would re-invalidate the entire terminal view hierarchy and
    /// cause visible lag during the drag (especially under zmx, where
    /// each layout pass forwards SIGWINCH through a second PTY).
    let onDragEnd: (Double) -> Void

    var body: some View {
        ProportionalSplitView(
            direction: direction == .horizontal ? .horizontal : .vertical,
            ratio: $ratio,
            first: left,
            second: right,
            onDragEnd: onDragEnd
        )
    }
}

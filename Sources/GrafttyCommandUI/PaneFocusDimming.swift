import SwiftUI

/// Cross-platform focus treatment for terminal split leaves. Ghostty's
/// `unfocused-split-opacity` is the resulting content opacity; painting the
/// configured split fill at its inverse produces the same treatment without
/// changing hit testing or making the terminal surface itself translucent.
public struct PaneFocusDimmingStyle: Equatable, Sendable {
    public let overlayOpacity: Double

    public static let hidden = PaneFocusDimmingStyle(overlayOpacity: 0)

    public init(
        isUnfocused: Bool,
        contentOpacity: Double
    ) {
        self.overlayOpacity = isUnfocused
            ? min(1, max(0, 1 - contentOpacity))
            : 0
    }

    public init(overlayOpacity: Double) {
        self.overlayOpacity = min(1, max(0, overlayOpacity))
    }

    public var isVisible: Bool {
        overlayOpacity > 0
    }
}

private struct PaneFocusDimmingModifier: ViewModifier {
    let fill: Color
    let style: PaneFocusDimmingStyle

    func body(content: Content) -> some View {
        content.overlay {
            if style.isVisible {
                Rectangle()
                    .fill(fill.opacity(style.overlayOpacity))
                    .clipped()
                    .allowsHitTesting(false)
            }
        }
    }
}

public extension View {
    func paneFocusDimming(
        fill: Color,
        style: PaneFocusDimmingStyle
    ) -> some View {
        modifier(PaneFocusDimmingModifier(fill: fill, style: style))
    }
}

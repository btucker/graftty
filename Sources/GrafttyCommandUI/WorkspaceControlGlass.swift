import SwiftUI

/// Native control material, with a system-material fallback on older releases.
public struct WorkspaceControlGlass: ViewModifier {
    public init() {}
    @ViewBuilder public func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

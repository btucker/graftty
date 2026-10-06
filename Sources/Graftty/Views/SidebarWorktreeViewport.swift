import SwiftUI

/// Pinned rows fit their content until they need half the available space.
/// Separate scroll views keep ordinary scrolling below the controls.
struct SidebarWorktreeViewport<Pinned: View, Controls: View, Content: View>: View {
    @ViewBuilder var pinned: () -> Pinned
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content
    @State private var pinnedHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let remaining = max(0, geometry.size.height - controlsHeight)
            let limit = min(remaining / 2, max(0, remaining - 96))
            let height = min(pinnedHeight, limit)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) { pinned() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pinnedHeight = $0 }
                }
                .scrollDisabled(pinnedHeight <= limit)
                .frame(height: height)
                controls()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                content().frame(maxHeight: .infinity)
            }
        }
    }
}

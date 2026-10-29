import SwiftUI

/// Pinned rows fit their content by default. Dragging overrides the height
/// until the pinned content changes size, including pin/unpin and disclosure.
struct SidebarWorktreeViewport<Pinned: View, Controls: View, Content: View>: View {
    var pinnedMembership: Set<String> = []
    var showsDivider = true
    @ViewBuilder var pinned: () -> Pinned
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content
    @State private var pinnedHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0
    @State private var requestedHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = showsDivider ? SidebarWorktreeDivider.thickness : 0
            let limit = max(0, geometry.size.height - controlsHeight - dividerHeight - 96)
            let height = pinnedHeight > 0 ? min(requestedHeight ?? pinnedHeight, limit) : 0
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) { pinned() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            pinnedHeight = $0
                            requestedHeight = nil
                            dragStartHeight = nil
                        }
                }
                .scrollDisabled(pinnedHeight <= height)
                .frame(height: height)
                if showsDivider {
                    SidebarWorktreeDivider(onResize: { translation in
                        if dragStartHeight == nil { dragStartHeight = height }
                        let minimum = min(pinnedHeight, min(20, limit))
                        requestedHeight = min(limit, max(minimum, (dragStartHeight ?? height) + translation))
                    }, onResizeEnd: { dragStartHeight = nil })
                    .frame(height: dividerHeight)
                }
                controls()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                content().frame(maxHeight: .infinity)
            }
        }
        .onChange(of: pinnedMembership) { _, _ in
            requestedHeight = nil
            dragStartHeight = nil
        }
    }
}

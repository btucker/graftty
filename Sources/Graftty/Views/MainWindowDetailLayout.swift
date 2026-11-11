import GrafttyCommandUI
import SwiftUI

/// The selected worktree detail keeps the breadcrumb above its content row.
struct MainWindowDetailLayout<Header: View, Content: View, Inspector: View>: View {
    var headerWash: WorktreeHeaderWash? = nil
    /// Starts the inspector below the content's tab row, when the content has one (CONTEXT-55).
    var inspectorTopInset: CGFloat = 0
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector
    @State private var width: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { WorktreeHeaderWashSpill() }
                inspector
                    .padding(.top, inspectorTopInset)
            }
            .contentShape(Rectangle())
            // Keep workspace backgrounds and hit targets below the window header.
            .clipped()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .coordinateSpace(name: WorktreeHeaderWash.coordinateSpace)
        .environment(\.worktreeHeaderWashBand, headerWash.map {
            WorktreeHeaderWashBand(wash: $0, size: CGSize(width: width, height: headerHeight + WorktreeHeaderWash.tabRowHeight))
        })
    }
}

extension MainWindowDetailLayout where Inspector == EmptyView {
    init(headerWash: WorktreeHeaderWash? = nil, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(headerWash: headerWash, header: header, content: content, inspector: { EmptyView() })
    }
}

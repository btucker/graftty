import GrafttyCommandUI
import SwiftUI

/// The height of the tab row a detail view draws at its top. Only content that
/// renders one reports it, so every other state leaves the default of zero.
struct WorkspaceTabRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The selected worktree detail keeps the breadcrumb above its content row.
struct MainWindowDetailLayout<Header: View, Content: View, Inspector: View>: View {
    var headerWash: WorktreeHeaderWash? = nil
    /// The tab row's background, continued above Context so no blank band shows (CONTEXT-63).
    var chromeBackground: Color? = nil
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector
    @State private var width: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var tabRowHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { WorktreeHeaderWashSpill() }
                    .onPreferenceChange(WorkspaceTabRowHeightKey.self) { tabRowHeight = $0 }
                // Starts below the content's tab row, when the content has one (CONTEXT-55).
                inspector
                    .padding(.top, tabRowHeight)
                    .background(alignment: .top) {
                        if tabRowHeight > 0, let chromeBackground {
                            chromeBackground.worktreeHeaderWash().frame(height: tabRowHeight)
                        }
                    }
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

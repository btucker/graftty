import SwiftUI

/// Reserves the area below the header even when empty content has a fixed height.
struct MainWindowDetailLayout<Header: View, Content: View, Inspector: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector
            }
            .contentShape(Rectangle())
            // Keep workspace backgrounds and hit targets below the window header.
            .clipped()
        }
    }
}

extension MainWindowDetailLayout where Inspector == EmptyView {
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content, inspector: { EmptyView() })
    }
}

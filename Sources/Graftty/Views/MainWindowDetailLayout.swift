import SwiftUI

/// Reserves the area below the header even when empty content has a fixed height.
struct MainWindowDetailLayout<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Workspace backgrounds must not extend into the titlebar
                // safe area and cover the preceding breadcrumb controls.
                .clipped()
        }
    }
}

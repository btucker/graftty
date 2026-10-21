import SwiftUI

/// Reserves the area below the header even when empty content has a fixed height.
struct MainWindowDetailLayout<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

import SwiftUI

/// Published by `SidebarView` via a background `GeometryReader` so the
/// hosting view (MainWindow) can observe the sidebar's rendered width and
/// persist it to AppState.
///
/// SwiftUI's `NavigationSplitView` on macOS 14 does not expose a binding
/// for column width, and `.onGeometryChange` requires macOS 15. A
/// preference key + background `GeometryReader` is the portable pattern.
struct SidebarWidthKey: PreferenceKey {
    static let defaultValue: Double = 0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        let candidate = nextValue()
        // Ignore spurious zero widths that SwiftUI emits during layout
        // passes — they'd clobber a valid measured width.
        if candidate > 0 {
            value = candidate
        }
    }
}

extension View {
    /// Publish the receiver's rendered width via `SidebarWidthKey`. Attach
    /// this to the sidebar column root; pair with `.onPreferenceChange` on
    /// an ancestor to react.
    func publishSidebarWidth() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarWidthKey.self, value: proxy.size.width)
            }
        )
    }
}

import SwiftUI

/// Published by a sidebar column via a background `GeometryReader` so the
/// hosting view can observe the sidebar's rendered width and persist it.
///
/// SwiftUI's `NavigationSplitView` doesn't expose a binding for column
/// width; this preference key + `publishSidebarWidth()` is the portable
/// pattern. Used by the Mac main window and the iPad layout.
public struct SidebarWidthKey: PreferenceKey {
    public static let defaultValue: Double = 0

    public static func reduce(value: inout Double, nextValue: () -> Double) {
        let candidate = nextValue()
        // Ignore spurious zero widths SwiftUI emits during layout passes.
        if candidate > 0 {
            value = candidate
        }
    }
}

public extension View {
    /// Publish the receiver's rendered width via `SidebarWidthKey`. Attach
    /// this to the sidebar column root; pair with `persistSidebarWidth(to:)`
    /// on an ancestor (or use the convenience modifier directly).
    func publishSidebarWidth() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarWidthKey.self, value: proxy.size.width)
            }
        )
    }

    /// Persist the published `SidebarWidthKey` value into the supplied
    /// binding, debouncing by 250ms so a drag doesn't write on every layout
    /// pass. Only writes if the binding's current value differs.
    func persistSidebarWidth(to binding: Binding<Double>) -> some View {
        modifier(SidebarWidthPersister(binding: binding))
    }
}

private struct SidebarWidthPersister: ViewModifier {
    let binding: Binding<Double>
    @State private var pendingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onPreferenceChange(SidebarWidthKey.self) { width in
            scheduleWrite(width)
        }
    }

    private func scheduleWrite(_ width: Double) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            if binding.wrappedValue != width {
                binding.wrappedValue = width
            }
        }
    }
}

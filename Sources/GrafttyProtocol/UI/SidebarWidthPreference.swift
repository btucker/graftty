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

/// Defers a published sidebar width's write until the drag that produced it
/// settles. Tests substitute a debounce they elapse by hand.
struct SidebarWidthDebounce: Sendable {
    typealias Cancel = @MainActor () -> Void

    /// Arranges for `write` to run once the debounce elapses, returning a
    /// cancellation for when a newer width supersedes it.
    let schedule: @MainActor @Sendable (_ write: @escaping @MainActor () -> Void) -> Cancel

    /// Writes 250ms after the last published width.
    static let standard = after(.milliseconds(250))

    /// Writes `delay` after the last published width.
    static func after(_ delay: Duration) -> SidebarWidthDebounce {
        SidebarWidthDebounce { write in
            let task = Task { @MainActor in
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { write() }
            }
            return { task.cancel() }
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarWidthDebounce = SidebarWidthDebounce.standard
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
    /// binding, debounced by the environment's `sidebarWidthDebounce`
    /// (250ms by default) so a drag doesn't write on every layout pass.
    /// Only writes if the binding's current value differs.
    func persistSidebarWidth(to binding: Binding<Double>, when enabled: Bool = true) -> some View {
        modifier(SidebarWidthPersister(binding: binding, enabled: enabled))
    }
}

private struct SidebarWidthPersister: ViewModifier {
    let binding: Binding<Double>
    let enabled: Bool
    @Environment(\.sidebarWidthDebounce) private var debounce
    @State private var cancelPendingWrite: SidebarWidthDebounce.Cancel?

    func body(content: Content) -> some View {
        content.onPreferenceChange(SidebarWidthKey.self) { width in
            guard enabled else { return }
            scheduleWrite(width)
        }
        .onChange(of: enabled) { _, _ in
            cancelPendingWrite?()
            cancelPendingWrite = nil
        }
    }

    private func scheduleWrite(_ width: Double) {
        cancelPendingWrite?()
        // `.onChange(of: enabled)` cancels this write if the gate closes.
        cancelPendingWrite = debounce.schedule {
            if binding.wrappedValue != width {
                binding.wrappedValue = width
            }
        }
    }
}

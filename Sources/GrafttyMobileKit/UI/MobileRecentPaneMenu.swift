#if canImport(UIKit)
import SwiftUI

struct MobileRecentPaneActions {
    let history: MobileRecentPanes
    let open: (MobileRecentPanes.Entry) -> Void
}

private struct MobileRecentPaneActionsKey: EnvironmentKey {
    static let defaultValue: MobileRecentPaneActions? = nil
}

extension EnvironmentValues {
    var recentPaneActions: MobileRecentPaneActions? {
        get { self[MobileRecentPaneActionsKey.self] }
        set { self[MobileRecentPaneActionsKey.self] = newValue }
    }
}

/// A native context menu leaves the button's ordinary tap action intact.
struct MobileTerminalBackButton: View {
    let accessibilityLabel: String
    let pendingCount: Int
    let entries: [MobileRecentPanes.Entry]
    let back: () -> Void
    let open: (MobileRecentPanes.Entry) -> Void

    var body: some View {
        TerminalFloatingGlyphButton(systemName: "chevron.left", accessibilityLabel: accessibilityLabel, action: back)
            .accessibilityIdentifier("terminal.back")
            .contextMenu {
                Section("Recent panes") {
                    if entries.isEmpty { Text("No recent panes") }
                    ForEach(entries) { entry in
                        Button(entry.label) { open(entry) }
                            .accessibilityIdentifier("recent-pane." + entry.id)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if pendingCount > 0 {
                    Text(pendingCount > 99 ? "99+" : "\(pendingCount)")
                        .font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                        .background(.orange, in: Capsule()).offset(x: 5, y: -5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
#endif

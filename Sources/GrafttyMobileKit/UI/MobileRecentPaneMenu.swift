#if canImport(UIKit)
import GrafttyCommandUI
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
    @Environment(\.colorScheme) private var colorScheme
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
                    Circle().fill(SidebarAttentionStyle.text(isDark: colorScheme == .dark))
                        .frame(width: 8, height: 8).offset(x: -6, y: 6)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
#endif

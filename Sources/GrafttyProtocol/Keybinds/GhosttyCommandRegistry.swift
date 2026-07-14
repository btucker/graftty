import Foundation

public enum GhosttyCommandKind: Sendable, Hashable {
    case split(GhosttySplitDirection)
    case closePane
    case focusPane(GhosttyPaneFocusDirection)
    case focusPaneByOrder(forward: Bool)
    case unsupported
}

public enum GhosttySplitDirection: String, Sendable, Hashable, Codable {
    case left
    case right
    case up
    case down
}

public enum GhosttyPaneFocusDirection: String, Sendable, Hashable, Codable {
    case left
    case right
    case up
    case down
}

public struct GhosttyCommandRegistry: Sendable {
    public struct Entry: Sendable, Hashable {
        public let action: GhosttyAction
        public let label: String
        public let kind: GhosttyCommandKind

        /// Derived from `iPadSupportedActions` membership so it can never
        /// disagree with the list — the list stays the single source of
        /// truth for iPad support (its order also sets chord-collision
        /// priority for mobile candidates).
        public var isSupportedOniPad: Bool {
            GhosttyCommandRegistry.iPadSupportedActionSet.contains(action)
        }

        public init(
            action: GhosttyAction,
            label: String,
            kind: GhosttyCommandKind
        ) {
            self.action = action
            self.label = label
            self.kind = kind
        }
    }

    public static let allActions: [Entry] = [
        .init(action: .newSplitRight, label: "Split Right", kind: .split(.right)),
        .init(action: .newSplitLeft, label: "Split Left", kind: .split(.left)),
        .init(action: .newSplitUp, label: "Split Up", kind: .split(.up)),
        .init(action: .newSplitDown, label: "Split Down", kind: .split(.down)),
        .init(action: .closeSurface, label: "Close Pane", kind: .closePane),
        .init(action: .gotoSplitLeft, label: "Focus Pane Left", kind: .focusPane(.left)),
        .init(action: .gotoSplitRight, label: "Focus Pane Right", kind: .focusPane(.right)),
        .init(action: .gotoSplitUp, label: "Focus Pane Up", kind: .focusPane(.up)),
        .init(action: .gotoSplitDown, label: "Focus Pane Down", kind: .focusPane(.down)),
        .init(action: .gotoSplitPrevious, label: "Previous Pane", kind: .focusPaneByOrder(forward: false)),
        .init(action: .gotoSplitNext, label: "Next Pane", kind: .focusPaneByOrder(forward: true)),
        .init(action: .nextTab, label: "Next Pane", kind: .focusPaneByOrder(forward: true)),
        .init(action: .previousTab, label: "Previous Pane", kind: .focusPaneByOrder(forward: false)),
        .init(action: .toggleSplitZoom, label: "Zoom Split", kind: .unsupported),
        .init(action: .equalizeSplits, label: "Equalize Splits", kind: .unsupported),
        .init(action: .reloadConfig, label: "Reload Ghostty Config", kind: .unsupported),
        .init(action: .openConfig, label: "Open Ghostty Settings", kind: .unsupported),
    ]

    public static let iPadSupportedActions: [GhosttyAction] = [
        .newSplitRight,
        .newSplitDown,
        .newSplitLeft,
        .newSplitUp,
        .closeSurface,
        .gotoSplitLeft,
        .gotoSplitRight,
        .gotoSplitUp,
        .gotoSplitDown,
        .gotoSplitPrevious,
        .gotoSplitNext,
        .nextTab,
        .previousTab,
    ]

    static let iPadSupportedActionSet = Set(iPadSupportedActions)

    private static let entriesByAction: [GhosttyAction: Entry] = Dictionary(
        uniqueKeysWithValues: allActions.map { ($0.action, $0) }
    )

    public static let macSplitActions: [Entry] = entries(for: [
        .newSplitRight,
        .newSplitLeft,
        .newSplitDown,
        .newSplitUp,
    ])

    public static let macPaneFocusActions: [Entry] = entries(for: [
        .gotoSplitLeft,
        .gotoSplitRight,
        .gotoSplitUp,
        .gotoSplitDown,
        .gotoSplitPrevious,
        .gotoSplitNext,
        .nextTab,
        .previousTab,
    ])

    public static let macPaneLayoutActions: [Entry] = entries(for: [
        .toggleSplitZoom,
        .equalizeSplits,
    ])

    public static let macPaneLifecycleActions: [Entry] = entries(for: [
        .closeSurface,
    ])

    public static let macSettingsActions: [Entry] = entries(for: [
        .openConfig,
        .reloadConfig,
    ])

    public static subscript(action: GhosttyAction) -> Entry? {
        entriesByAction[action]
    }

    private static func entries(for actions: [GhosttyAction]) -> [Entry] {
        actions.map { action in
            guard let entry = entriesByAction[action] else {
                preconditionFailure("Missing Ghostty command registry entry for \(action.rawValue)")
            }
            return entry
        }
    }
}

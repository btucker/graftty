import Foundation

public enum GhosttyCommandKind: Sendable, Hashable {
    case split(GhosttySplitDirection)
    case closePane
    case focusPane(GhosttyPaneFocusDirection)
    case focusPaneByOrder(forward: Bool)
    case navigateWorktree(forward: Bool)
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
        public let isSupportedOnMac: Bool
        public let isSupportedOniPad: Bool

        public init(
            action: GhosttyAction,
            label: String,
            kind: GhosttyCommandKind,
            isSupportedOnMac: Bool,
            isSupportedOniPad: Bool
        ) {
            self.action = action
            self.label = label
            self.kind = kind
            self.isSupportedOnMac = isSupportedOnMac
            self.isSupportedOniPad = isSupportedOniPad
        }
    }

    public static let allActions: [Entry] = [
        .init(action: .newSplitRight, label: "Split Right", kind: .split(.right), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .newSplitLeft, label: "Split Left", kind: .split(.left), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .newSplitUp, label: "Split Up", kind: .split(.up), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .newSplitDown, label: "Split Down", kind: .split(.down), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .closeSurface, label: "Close Pane", kind: .closePane, isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitLeft, label: "Focus Pane Left", kind: .focusPane(.left), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitRight, label: "Focus Pane Right", kind: .focusPane(.right), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitUp, label: "Focus Pane Up", kind: .focusPane(.up), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitDown, label: "Focus Pane Down", kind: .focusPane(.down), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitPrevious, label: "Previous Pane", kind: .focusPaneByOrder(forward: false), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .gotoSplitNext, label: "Next Pane", kind: .focusPaneByOrder(forward: true), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .nextTab, label: "Next Worktree", kind: .navigateWorktree(forward: true), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .previousTab, label: "Previous Worktree", kind: .navigateWorktree(forward: false), isSupportedOnMac: true, isSupportedOniPad: true),
        .init(action: .toggleSplitZoom, label: "Zoom Split", kind: .unsupported, isSupportedOnMac: true, isSupportedOniPad: false),
        .init(action: .equalizeSplits, label: "Equalize Splits", kind: .unsupported, isSupportedOnMac: true, isSupportedOniPad: false),
        .init(action: .reloadConfig, label: "Reload Ghostty Config", kind: .unsupported, isSupportedOnMac: true, isSupportedOniPad: false),
        .init(action: .openConfig, label: "Open Ghostty Settings", kind: .unsupported, isSupportedOnMac: true, isSupportedOniPad: false),
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
    ])

    public static let macWorktreeNavigationActions: [Entry] = entries(for: [
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

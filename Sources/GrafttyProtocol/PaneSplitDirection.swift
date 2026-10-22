import Foundation

/// Four-way pane split direction: where the new pane appears relative to the
/// target. One type serves the CLI/socket (`PaneSplit`), keybinds
/// (`GhosttySplitDirection`) and remote pane control
/// (`PaneControlRequest.SplitDirection`). It codes as its raw value; the
/// pane-control wire keeps its legacy right/down tokens inside
/// `PaneControlRequest`'s coder (`REMOTE-7.7`).
public enum PaneSplitDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case right
    case down
    case left
    case up
}

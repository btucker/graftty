import Foundation

/// Four-way pane split direction — carries enough information for the
/// context-menu / CLI callers to pick both the `SplitDirection`
/// (horizontal/vertical) and the placement (new pane before or after the
/// target). Lives in GrafttyKit so the CLI and wire protocol can share
/// the same enum with the app layer.
public enum PaneSplit: String, Codable, Sendable {
    case right, left, up, down
}

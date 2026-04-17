import Foundation

/// Subset of Ghostty apprt actions Espalier exposes as menu items and
/// queries in `GhosttyKeybindBridge`. `rawValue` is the exact string
/// Ghostty's config parser accepts on the RHS of `keybind = chord=...`.
///
/// Changing a raw value orphans the bridge — menu shortcut hints will
/// silently stop resolving. Tests pin every string.
public enum GhosttyAction: String, CaseIterable, Sendable {
    case newSplitRight = "new_split:right"
    case newSplitLeft  = "new_split:left"
    case newSplitUp    = "new_split:up"
    case newSplitDown  = "new_split:down"
    case closeSurface  = "close_surface"
    case gotoSplitLeft   = "goto_split:left"
    case gotoSplitRight  = "goto_split:right"
    case gotoSplitUp   = "goto_split:up"
    case gotoSplitDown = "goto_split:down"
    case gotoSplitPrevious = "goto_split:previous"
    case gotoSplitNext     = "goto_split:next"
    case toggleSplitZoom = "toggle_split_zoom"
    case equalizeSplits  = "equalize_splits"
    case reloadConfig    = "reload_config"
}

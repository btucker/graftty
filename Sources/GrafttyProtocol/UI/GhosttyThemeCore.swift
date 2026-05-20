import SwiftUI

/// Cross-platform snapshot of the ghostty-config-driven theme colors
/// Graftty applies to app chrome (sidebar, breadcrumb). The Mac wraps
/// this in `GhosttyTheme` (adding NSColor + NSAppearance accessors);
/// mobile constructs it by parsing the Mac-resolved config text via
/// `init(parsingConfigText:)` (in GrafttyMobileKit/Theme).
public struct GhosttyThemeColors: Sendable, Equatable {

    public struct RGB: Sendable, Equatable {
        public let r: Double
        public let g: Double
        public let b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    public let backgroundRGB: RGB
    public let foregroundRGB: RGB

    public init(backgroundRGB: RGB, foregroundRGB: RGB) {
        self.backgroundRGB = backgroundRGB
        self.foregroundRGB = foregroundRGB
    }

    public var background: Color { Self.color(backgroundRGB) }
    public var foreground: Color { Self.color(foregroundRGB) }
    public var sidebarBackground: Color { Self.color(sidebarBackgroundRGB) }

    public var sidebarBackgroundRGB: RGB {
        let shift = isDark ? 0.06 : -0.06
        return RGB(
            r: Self.clamp01(backgroundRGB.r + shift),
            g: Self.clamp01(backgroundRGB.g + shift),
            b: Self.clamp01(backgroundRGB.b + shift)
        )
    }

    public var isDark: Bool {
        let bg = backgroundRGB
        let luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
        // The canonical mid-gray (r=g=b=0.5, theoretical luminance=0.5) needs
        // to land on the boundary (treated as light, not dark) — but IEEE 754
        // accumulation gives 0.49999999999999994 for these coefficients. An
        // epsilon catches the boundary case without altering far-from-boundary
        // decisions.
        if abs(luminance - 0.5) < 1e-9 { return false }
        return luminance < 0.5
    }

    public static let fallback = GhosttyThemeColors(
        backgroundRGB: RGB(r: 0.05, g: 0.05, b: 0.10),
        foregroundRGB: RGB(r: 0.87, g: 0.87, b: 0.87)
    )

    private static func color(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    private static func clamp01(_ x: Double) -> Double {
        min(1.0, max(0.0, x))
    }
}

// MARK: - Sidebar text-color palette
//
// Single source of truth for the opacity ladders the Mac sidebar (and now
// the iPad sidebar) apply on top of `foreground`. Centralized here so the
// two surfaces don't drift — the Mac was the reference; the constants
// below are lifted verbatim from `SidebarView.swift` / `WorktreeRow.swift`.
public extension GhosttyThemeColors {

    /// Primary worktree-row text. Active rows go full-brightness; inactive
    /// rows dim slightly so the selected row reads as emphasized.
    static func sidebarPrimaryOpacity(isActive: Bool) -> Double {
        isActive ? 1.0 : 0.8
    }

    /// Strikethrough row text for stale (orphaned) worktrees.
    static let sidebarStaleOpacity: Double = 0.5

    /// Dim secondary label (e.g. branch name beside the worktree name,
    /// divergence-gutter ahead-side, "Add worktree" plus-button glyph at
    /// rest).
    static let sidebarSecondaryOpacity: Double = 0.45

    /// Foreground-derived dim icon — used by the worktree-row type icon
    /// when the worktree is closed/creating/deleting (states without a
    /// dedicated state color like running's green or stale's yellow).
    static let sidebarDimIconOpacity: Double = 0.6

    /// Host-header chevron + section-header caption dim.
    static let sidebarChevronOpacity: Double = 0.55

    /// Pane-row `↳` arrow brightness ladder. The brightest treatment goes
    /// to the focused pane (typing lands here); panes inside the active
    /// worktree are dimmer; panes in inactive worktrees are dimmest.
    static func paneArrowOpacity(isFocusedPane: Bool, isActiveWorktree: Bool) -> Double {
        if isFocusedPane { return 0.75 }
        return isActiveWorktree ? 0.5 : 0.35
    }

    /// Pane-row title brightness ladder. Four buckets so the eye can parse
    /// hierarchy at a glance: focused-in-active > non-focused-in-active
    /// > inactive — with empty titles ("shell" placeholder) dimmer than
    /// real titles within their bucket. Tuned alongside the 0.16-alpha
    /// active-block highlight on the Mac so contrast holds on both light
    /// and dark themes.
    static func paneTitleOpacity(
        isFocusedPane: Bool,
        isActiveWorktree: Bool,
        hasTitle: Bool
    ) -> Double {
        if isFocusedPane { return 1.0 }
        if isActiveWorktree { return hasTitle ? 0.75 : 0.55 }
        return hasTitle ? 0.55 : 0.35
    }

    func sidebarPrimaryText(isActive: Bool) -> Color {
        foreground.opacity(Self.sidebarPrimaryOpacity(isActive: isActive))
    }

    var sidebarStaleText: Color {
        foreground.opacity(Self.sidebarStaleOpacity)
    }

    var sidebarSecondaryText: Color {
        foreground.opacity(Self.sidebarSecondaryOpacity)
    }

    var sidebarDimIcon: Color {
        foreground.opacity(Self.sidebarDimIconOpacity)
    }

    var sidebarChevron: Color {
        foreground.opacity(Self.sidebarChevronOpacity)
    }

    func paneArrow(isFocusedPane: Bool, isActiveWorktree: Bool) -> Color {
        foreground.opacity(Self.paneArrowOpacity(
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree
        ))
    }

    func paneTitle(isFocusedPane: Bool, isActiveWorktree: Bool, hasTitle: Bool) -> Color {
        foreground.opacity(Self.paneTitleOpacity(
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree,
            hasTitle: hasTitle
        ))
    }
}

// MARK: - Themed sidebar surface (shared with Mac sidebar)

public extension View {
    /// Standard themed-sidebar surface treatment used by both the Mac
    /// SidebarView and the iPad WorktreeListContent host:
    ///  - `.scrollContentBackground(.hidden)` so the enclosed `List`'s
    ///    default material doesn't obscure the ghostty palette.
    ///  - `.background(theme.sidebarBackground)` so the slightly
    ///    shifted (`±6%` luminance) ghostty background paints behind
    ///    the rows. Combined with a transparent list, the sidebar reads
    ///    as a "lighter version" of the terminal area on dark themes
    ///    (and "darker version" on light themes) — exactly the Mac
    ///    sidebar appearance.
    ///
    /// Apply to the *container* that holds the `List` (typically the
    /// `VStack` that owns header + list + footer); `scrollContentBackground`
    /// propagates down to any descendant scroll content.
    func themedSidebarSurface(_ theme: GhosttyThemeColors) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.sidebarBackground)
    }
}

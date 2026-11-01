import SwiftUI
import GrafttyProtocol

/// Red attention pill shared by the Mac and mobile sidebars: worktree rows
/// use it for worktree-scoped pings, pane rows for pane-scoped pings. One
/// definition keeps a restyle (font, padding, color) from drifting.
public struct AttentionCapsule: View {
    public let style: AttentionCapsuleStyle

    public init(style: AttentionCapsuleStyle) {
        self.style = style
    }

    public var body: some View {
        switch style {
        case let .needsInput(label):
            // Agent "needs input" is a bare red icon (no pill) — the glyph
            // itself is the badge. Text is kept for accessibility + tooltip.
            Image(systemName: AttentionCapsuleStyle.needsInputSymbol)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
                .accessibilityLabel(label)
                #if os(macOS)
                .help(label)
                #endif
        case let .text(text):
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }
}

/// Pane title text with the sidebar's emphasis rules, shared by the Mac and
/// mobile pane rows.
public struct SidebarPaneTitleText: View {
    let title: String
    let isFocusedPane: Bool
    let isActiveWorktree: Bool
    let isBusy: Bool
    let attentionStyle: AttentionCapsuleStyle?
    var isAgent = false
    let theme: GhosttyThemeColors?

    public var body: some View {
        // AGENT-2.2: a busy pane renders its (already-animating) title in
        // italic — a quiet "working" cue rather than a color shift. Apply
        // italic at the *Text* level (Text.italic(), not the View
        // `.italic(_:)` modifier): when a Text-level `.fontWeight` is set,
        // the focused pane's `.semibold` wins over the View-level italic and
        // drops it, so the slant only showed on non-focused (regular) rows.
        // Busy style applies only when no capsule is shown (ping supersedes).
        let base = Text(title.isEmpty ? "shell" : title)
            .font(isAgent ? .system(size: 13) : .caption)
            .fontWeight(isFocusedPane ? .semibold : .regular)
        (PaneTitleBusyStyle.applies(isBusy: isBusy, hasAttentionCapsule: attentionStyle != nil) ? base.italic() : base)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(titleStyle)
    }

    /// LAYOUT-2.31: the agent "needs input" state colors the title red too
    /// (alongside the red icon) so it's scannable, not just a small glyph.
    /// Without a theme (compact mobile) the title stays on the system
    /// `.secondary` style.
    private var titleStyle: AnyShapeStyle {
        if case .needsInput = attentionStyle { return AnyShapeStyle(.red) }
        // An unset title hits the dimmer placeholder bucket.
        guard let color = theme?.paneTitle(isFocusedPane: isFocusedPane,
                                           isActiveWorktree: isActiveWorktree,
                                           hasTitle: !title.isEmpty) else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color)
    }
}

/// Child row under a running worktree showing one pane's title, shared by
/// the Mac and mobile sidebars. The marker slot holds the `↳` glyph or the
/// pane's attention count; an attention capsule renders to the *right* of
/// the title (LAYOUT-2.30), which truncates to make room. Without a capsule
/// the title passes through `titleLayout`, where the Mac flows port chips
/// after it (PORTS-3.3).
public struct SidebarPaneTitleRow<TitleLayout: View>: View {
    let title: SidebarPaneTitleText
    let attentionCount: Int
    let needsInput: Bool
    let agent: AgentSessionInfo?
    let alignment: VerticalAlignment
    /// Built once at init rather than stored as a closure, so SwiftUI can
    /// still diff the row by value.
    let titleLayout: TitleLayout

    /// - Parameters:
    ///   - title: The pane's raw title; empty renders the "shell" placeholder.
    ///   - isFocusedPane: The single pane with keyboard focus in the active
    ///     worktree; gets the brightest text and a bolder `↳`.
    ///   - isActiveWorktree: The row's worktree is selected, so its panes
    ///     read brighter than panes in other worktrees.
    ///   - theme: `nil` falls back to system `.secondary` styling.
    public init(
        title: String,
        isFocusedPane: Bool,
        isActiveWorktree: Bool,
        isBusy: Bool,
        attentionStyle: AttentionCapsuleStyle?,
        attentionCount: Int,
        theme: GhosttyThemeColors?,
        needsInput: Bool = false,
        agent: AgentSessionInfo? = nil,
        alignment: VerticalAlignment = .center,
        @ViewBuilder titleLayout: (SidebarPaneTitleText) -> TitleLayout
    ) {
        let titleText = SidebarPaneTitleText(title: title, isFocusedPane: isFocusedPane,
                                             isActiveWorktree: isActiveWorktree, isBusy: isBusy,
                                             attentionStyle: attentionStyle, isAgent: agent != nil, theme: theme)
        self.title = titleText
        self.attentionCount = attentionCount
        self.needsInput = needsInput
        self.agent = agent
        self.alignment = alignment
        self.titleLayout = titleLayout(titleText)
    }

    public var body: some View {
        HStack(alignment: alignment, spacing: SidebarPaneLayout.markerSpacing) {
            if let agent {
                AgentStatusBadge(status: agent.status, needsInput: needsInput,
                    failure: agent.failure, processObservation: agent.processObservation)
                    .font(.system(size: 12)).frame(width: 18)
            } else if attentionCount > 0 {
                SidebarPaneMarker(attentionCount: attentionCount, isFocused: false,
                    arrowColor: title.theme?.foreground ?? .secondary)
            }
            if let attentionStyle = title.attentionStyle {
                // A plain HStack — not the caller's layout — so the title
                // truncates instead of the pill wrapping below it.
                title
                    .layoutPriority(0)
                AttentionCapsule(style: attentionStyle)
                    .layoutPriority(1)
            } else {
                titleLayout
            }
            Spacer(minLength: 0)
        }
        .opacity(agent?.completionID != nil || agent?.status == "closed" ? 0.5 : 1)
    }
}

public extension SidebarPaneTitleRow where TitleLayout == SidebarPaneTitleText {
    init(
        title: String,
        isFocusedPane: Bool,
        isActiveWorktree: Bool,
        isBusy: Bool,
        attentionStyle: AttentionCapsuleStyle?,
        attentionCount: Int,
        theme: GhosttyThemeColors?,
        needsInput: Bool = false,
        agent: AgentSessionInfo? = nil
    ) {
        self.init(title: title, isFocusedPane: isFocusedPane, isActiveWorktree: isActiveWorktree,
                  isBusy: isBusy, attentionStyle: attentionStyle, attentionCount: attentionCount,
                  theme: theme, needsInput: needsInput, agent: agent) { $0 }
    }
}

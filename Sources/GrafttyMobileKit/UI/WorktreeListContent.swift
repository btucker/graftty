#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

public struct WorktreeListContent: View {
    @State private var state: LoadState = .loading
    @State private var isAddSheetPresented: Bool = false
    @State private var pendingDelete: PendingDelete?
    @State private var pendingForceDelete: PendingForceDelete?
    @State private var errorToast: String?
    @State private var errorToastTask: Task<Void, Never>?

    private struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let worktree: WorktreePanes
        let action: WorktreePickerSwipeAction
    }

    private struct PendingForceDelete: Identifiable, Equatable {
        let id = UUID()
        let worktreePath: String
        let stderr: String
        let shortStatus: String
    }

    public let host: Host
    /// Ghostty palette for theming row text. nil keeps the system colors
    /// in use on the compact (iPhone) path, where the List renders against
    /// the standard grouped-list background; the iPad sidebar paints a
    /// themed background so it supplies a non-nil theme here.
    public let theme: GhosttyThemeColors?
    /// Path of the currently-active worktree (iPad: `appState
    /// .selectedWorktreePath`). When non-nil, the matching worktree
    /// block renders with the active highlight (IPAD-1.16) and its
    /// pane rows pick the active-worktree brightness bucket.
    public let selectedWorktreePath: String?
    /// Session name of the focused pane (iPad: `appState.focusedPaneId`).
    /// When set, the matching pane row uses the brightest focused
    /// bucket via `theme.paneTitle(isFocusedPane: true, …)`.
    public let focusedPaneId: String?
    public let onSelect: (WorktreePanes) -> Void
    public let onSelectPane: (PaneLayoutNode.Leaf) -> Void
    public let onListChanged: ([WorktreePanes]) -> Void

    public init(
        host: Host,
        theme: GhosttyThemeColors? = nil,
        selectedWorktreePath: String? = nil,
        focusedPaneId: String? = nil,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void,
        onListChanged: @escaping ([WorktreePanes]) -> Void = { _ in }
    ) {
        self.host = host
        self.theme = theme
        self.selectedWorktreePath = selectedWorktreePath
        self.focusedPaneId = focusedPaneId
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onListChanged = onListChanged
    }

    private enum LoadState {
        case loading
        case loaded([WorktreePanes])
        case error(String)
    }

    public var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .error(let msg):
                ContentUnavailableView {
                    Label("Couldn't load worktrees", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let worktrees):
                List {
                    ForEach(WorktreePickerGrouping.grouped(worktrees), id: \.0) { repoName, entries in
                        Section {
                            ForEach(entries, id: \.path) { wt in
                                WorktreeBlock(
                                    worktree: wt,
                                    theme: theme,
                                    isActive: wt.path == selectedWorktreePath,
                                    focusedPaneId: focusedPaneId,
                                    onSelect: { onSelect(wt) },
                                    onSelectPane: onSelectPane
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let action = WorktreePickerGrouping.swipeAction(for: wt) {
                                        Button(role: .destructive) {
                                            pendingDelete = PendingDelete(worktree: wt, action: action)
                                        } label: {
                                            Label(action.buttonLabel, systemImage: action == .dismiss ? "eye.slash" : "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text(repoName)
                                .foregroundColor(theme?.sidebarPrimaryText(isActive: false))
                        }
                    }
                }
                // Mac-parity: `.sidebar` style + transparent scroll content
                // so the ghostty `sidebarBackground` painted by the
                // enclosing `IPadRootLayout`'s `themedSidebarSurface`
                // shows through. Without these, iOS overlays a grouped-
                // list material that hides the themed background.
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .refreshable { await refresh() }
            }
        }
        .confirmationDialog(
            pendingDelete?.action.dialogTitle ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pending in
            Button(pending.action.buttonLabel, role: .destructive) {
                Task { await performDelete(worktree: pending.worktree, force: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.action.dialogBody)
        }
        .confirmationDialog(
            "Could not delete worktree",
            isPresented: Binding(
                get: { pendingForceDelete != nil },
                set: { if !$0 { pendingForceDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForceDelete
        ) { pending in
            Button("Force Delete", role: .destructive) {
                let path = pending.worktreePath
                Task { await performForceDelete(worktreePath: path) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.stderr + (pending.shortStatus.isEmpty ? "" : "\n\n" + pending.shortStatus))
        }
        .overlay(alignment: .bottom) {
            if let msg = errorToast {
                Text(msg)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Title is owned by the caller: the iPhone compact path
        // (`WorktreePickerView`) sets `.navigationTitle(host.label)` for
        // the navigation-stack push; the iPad path uses `HostMenu` (in
        // the sidebar nav bar's `.topBarLeading` slot) as the sole host
        // indicator, so adding `.navigationTitle` here would render a
        // redundant title in the sidebar's system nav bar (IPAD-1.2).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddSheetPresented = true
                } label: {
                    Label("Add Worktree", systemImage: "plus")
                }
                .accessibilityLabel("Add Worktree")
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddWorktreeSheetView(host: host) { response in
                Task { await handleCreated(response) }
            }
        }
        // Keyed on host.id so switching hosts via `HostMenu` (IPAD-6.1)
        // tears down the previous fetch and re-runs `load()` for the new
        // host, refreshing worktrees and theme.
        .task(id: host.id) { await load() }
        .onDisappear { errorToastTask?.cancel() }
    }

    private func load() async {
        state = .loading
        await refresh()
    }

    private func refresh() async {
        do {
            let list = try await WorktreePanesFetcher.fetch(baseURL: host.baseURL)
            state = .loaded(list)
            onListChanged(list)
        } catch WorktreePanesFetcher.FetchError.forbidden {
            state = .error("Not authorized — is this device on your tailnet?")
        } catch WorktreePanesFetcher.FetchError.http(let code) {
            state = .error("HTTP \(code)")
        } catch WorktreePanesFetcher.FetchError.decode {
            state = .error("The server sent a response this version can't read.")
        } catch {
            state = .error("Couldn't reach the server.")
        }
    }

    /// Re-fetch without blanking the existing list so the user isn't
    /// shown a spinner over a list they just saw populated.
    private func handleCreated(_ response: CreateWorktreeClient.Response) async {
        await refresh()
        guard case .loaded(let list) = state else { return }
        if let match = list.first(where: { $0.path == response.worktreePath }) {
            onSelect(match)
        }
    }

    /// Issue the delete request; on success refresh in place, on
    /// forceable failure surface the Force Delete confirmation, on
    /// any other failure surface a transient error toast.
    private func performDelete(worktree: WorktreePanes, force: Bool) async {
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: host.baseURL,
                body: DeleteWorktreeClient.Request(worktreePath: worktree.path, force: force)
            )
            await refresh()
        } catch let DeleteWorktreeClient.DeleteError.gitFailedForceable(stderr, status) {
            pendingForceDelete = PendingForceDelete(
                worktreePath: worktree.path,
                stderr: stderr,
                shortStatus: status
            )
        } catch let error as DeleteWorktreeClient.DeleteError {
            surfaceDeleteError(error)
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    /// User confirmed Force Delete on a 409 forceable response —
    /// re-issue with `force: true`.
    private func performForceDelete(worktreePath: String) async {
        do {
            _ = try await DeleteWorktreeClient.delete(
                baseURL: host.baseURL,
                body: DeleteWorktreeClient.Request(worktreePath: worktreePath, force: true)
            )
            await refresh()
        } catch let error as DeleteWorktreeClient.DeleteError {
            surfaceDeleteError(error)
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    /// Surface an error after a delete attempt. Toasts the user-facing
    /// message and re-fetches only when the list actually changed
    /// server-side (`.notFound` means the row vanished between the
    /// picker render and the delete request).
    private func surfaceDeleteError(_ error: DeleteWorktreeClient.DeleteError) {
        if let msg = error.userMessage {
            showErrorToast(msg)
        }
        if case .notFound = error {
            Task { await refresh() }
        }
    }

    private func showErrorToast(_ message: String) {
        errorToastTask?.cancel()
        withAnimation { errorToast = message }
        errorToastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation { errorToast = nil }
                }
            }
        }
    }

}

private struct WorktreeBlock: View {
    let worktree: WorktreePanes
    let theme: GhosttyThemeColors?
    /// True when this worktree's path matches `selectedWorktreePath`
    /// (IPAD-1.16). Drives both the rounded-rectangle background
    /// highlight on the whole block and the active brightness bucket
    /// for pane rows beneath it.
    let isActive: Bool
    /// Session name of the focused pane within `appState`. Each pane
    /// row tests `leaf.sessionName == focusedPaneId` to decide whether
    /// to use the brightest focused bucket from `theme.paneTitle(…)`.
    let focusedPaneId: String?
    let onSelect: () -> Void
    let onSelectPane: (PaneLayoutNode.Leaf) -> Void

    var body: some View {
        // IPAD-1.13: pack the worktree row + its pane rows into a
        // single List row via a tight VStack so the iOS sidebar-list
        // style's default per-row padding doesn't compound between
        // panes. A small 3pt inter-row spacing gives breathing room
        // between consecutive pane rows without re-inflating to the
        // sidebar-style's full per-row padding.
        VStack(alignment: .leading, spacing: 3) {
            worktreeRow
            paneRows
        }
        // IPAD-1.16: active-worktree block highlight (Mac parity).
        // Painted on the whole VStack so the rounded rectangle spans
        // both the worktree row and its pane children — same visual
        // grouping as the Mac sidebar's `worktreeBlock`.
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlightFill)
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowSeparator(.hidden)
    }

    /// Themed active-worktree fill when available, else `.clear`. The
    /// 0.16 alpha matches the Mac sidebar's chosen contrast on top of
    /// `theme.sidebarBackground`.
    private var highlightFill: Color {
        guard isActive else { return .clear }
        if let theme {
            return theme.foreground.opacity(0.16)
        }
        return Color.primary.opacity(0.12)
    }

    @ViewBuilder
    private var worktreeRow: some View {
        if worktree.state.isInFlight {
            // Non-tappable: on-disk path may not exist yet
            // (`.creating`) or is about to vanish (`.deleting`).
            WorktreeRowContent(worktree: worktree, theme: theme, isActive: isActive)
        } else {
            Button(action: onSelect) {
                WorktreeRowContent(worktree: worktree, theme: theme, isActive: isActive)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var paneRows: some View {
        if let layout = worktree.layout {
            // IOS-4.21: pane child rows beneath multi-leaf worktrees
            // are tappable and route straight to the fullscreen
            // terminal, skipping the worktree-detail preview screen.
            // Single-leaf worktrees already shortcut at the worktree
            // row (IOS-4.17), so their pane row stays informational
            // to avoid two tap targets that do the same thing.
            //
            // IPAD-1.14: the first leaf inherits the worktree-scoped
            // `attentionText` (from `graftty notify`) when it has no
            // pane-scoped attention of its own — so "needs input"
            // pills always live on pane rows, never on the worktree
            // title row.
            ForEach(Array(layout.leaves.enumerated()), id: \.element.sessionName) { index, leaf in
                let effective = leaf.attentionText
                    ?? (index == 0 ? worktree.attentionText : nil)
                let isFocused = leaf.sessionName == focusedPaneId
                if layout.isLeaf {
                    PaneTitleRow(
                        leaf: leaf,
                        theme: theme,
                        effectiveAttentionText: effective,
                        isFocusedPane: isFocused,
                        isActiveWorktree: isActive
                    )
                } else {
                    Button { onSelectPane(leaf) } label: {
                        PaneTitleRow(
                            leaf: leaf,
                            theme: theme,
                            effectiveAttentionText: effective,
                            isFocusedPane: isFocused,
                            isActiveWorktree: isActive
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Wrap a themed `Color` in an `AnyShapeStyle`, falling back to the
/// system `.secondary` style when no theme is supplied. Used by the row
/// helpers below so each row site doesn't re-spell the same `if let`.
private func themedOrSecondary(_ themed: Color?) -> AnyShapeStyle {
    themed.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
}

/// Type icon + optional PR badge + display name (italic for main
/// checkout, strikethrough when stale), optional secondary branch
/// label stacked beneath the display name when present (IPAD-1.15),
/// and a trailing divergence gutter.
private struct WorktreeRowContent: View {
    let worktree: WorktreePanes
    let theme: GhosttyThemeColors?
    /// True when this worktree is the active one — drives the primary
    /// label's brightness bucket via `theme.sidebarPrimaryText
    /// (isActive: …)` so the selected row reads brighter than its
    /// siblings (IPAD-1.16).
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            typeIcon
            if let badge = worktree.prBadge {
                PRBadgeLabel(badge: badge)
            }
            // IPAD-1.15: the branch label gets its own line beneath
            // the worktree's display name rather than running inline.
            // Two-line stack keeps long names + long branches from
            // squishing each other or pushing the divergence gutter
            // off the trailing edge at narrow sidebar widths.
            VStack(alignment: .leading, spacing: 1) {
                primaryText
                if let secondary = secondaryBranch {
                    Text(secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                }
            }
            // IPAD-1.14: worktree-scoped attentionText is rendered on
            // the first pane row (see WorktreeBlock.paneRows), not
            // here — "needs input" pills always sit on pane rows.
            Spacer()
            DivergenceGutter(stats: worktree.stats, theme: theme)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var typeIcon: some View {
        if worktree.state.isInFlight {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(
                isMainCheckout: worktree.isMainCheckout,
                hasPR: worktree.prBadge != nil
            ))
            .font(.system(size: 11))
            .foregroundStyle(typeIconStyle)
            .frame(width: 14)
        }
    }

    /// Themed dim for closed/creating/deleting (falls back to system
    /// `.secondary` when no theme is supplied — i.e., compact iPhone
    /// path), green when running, yellow when stale. The themed path
    /// goes through the shared `GhosttyThemeColors.worktreeStateIcon`
    /// accessor so the Mac sidebar uses identical state-to-color
    /// mapping.
    private var typeIconStyle: AnyShapeStyle {
        if let theme {
            return AnyShapeStyle(theme.worktreeStateIcon(worktree.state))
        }
        // No-theme (compact iPhone) path: keep the system `.secondary`
        // dim for inactive states so the row reads against the system
        // grouped-list background.
        switch worktree.state {
        case .closed, .creating, .deleting: return AnyShapeStyle(.secondary)
        case .running: return AnyShapeStyle(Color.green)
        case .stale: return AnyShapeStyle(Color.yellow)
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        let primary = theme?.sidebarPrimaryText(isActive: isActive)
        if worktree.state == .stale {
            Text(worktree.displayName)
                .strikethrough()
                .foregroundStyle(themedOrSecondary(theme?.sidebarStaleText))
        } else if worktree.isMainCheckout {
            Text(worktree.displayName)
                .italic()
                .foregroundColor(primary)
        } else {
            Text(worktree.displayName)
                .foregroundColor(primary)
        }
    }

    /// Skip the dim branch label when it duplicates the primary
    /// display name — showing both is noise.
    private var secondaryBranch: String? {
        let branch = worktree.displayBranch
        guard !branch.isEmpty, branch != worktree.displayName else { return nil }
        return branch
    }
}

/// Pane child row: `↳` glyph + caption-sized title. When the pane has
/// a shell-integration ping (or the caller has attached the
/// worktree-scoped `attentionText` here per IPAD-1.14), an attention
/// capsule renders to the *right* of the title — not in place of it —
/// truncating the title to make room (LAYOUT-2.30).
private struct PaneTitleRow: View {
    let leaf: PaneLayoutNode.Leaf
    let theme: GhosttyThemeColors?
    /// The attention text the caller wants this pane row to display.
    /// Normally `leaf.attentionText`, but the first pane in a worktree
    /// also inherits `worktree.attentionText` as a fallback so the
    /// worktree-scoped `graftty notify` ping shows on a pane row
    /// instead of the worktree title row.
    let effectiveAttentionText: String?
    /// True when this leaf is the currently-focused pane. Drives the
    /// brightest bucket on `theme.paneArrow` and `theme.paneTitle`
    /// (IPAD-1.16), and bolds the arrow + title — matching the Mac
    /// sidebar's focused-pane treatment.
    let isFocusedPane: Bool
    /// True when this leaf's worktree is the active one. Drives the
    /// middle bucket on the brightness ladders so non-focused panes
    /// inside the active worktree still read brighter than panes in
    /// other worktrees.
    let isActiveWorktree: Bool

    var body: some View {
        // Busy style applies only when no capsule is shown — a needs-input
        // ping (claude waiting) supersedes "working". Shared with the Mac
        // row via PaneTitleBusyStyle so the precedence rule can't drift.
        let busyStyle = PaneTitleBusyStyle.applies(
            isBusy: leaf.isBusy, hasAttentionCapsule: effectiveAttentionText != nil)
        HStack(spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundStyle(themedOrSecondary(theme?.paneArrow(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree
                )))
            // LAYOUT-2.30: title (truncates) then pill (intrinsic width).
            // AGENT-2.2: a busy pane renders its title in italic.
            Text(leaf.displayTitle)
                .font(.caption)
                .fontWeight(isFocusedPane ? .semibold : .regular)
                .italic(busyStyle)
                .foregroundStyle(themedOrSecondary(theme?.paneTitle(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree,
                    // Use the raw title (not displayTitle, which falls back
                    // to a non-empty "shell"): an unset title should hit the
                    // dimmer placeholder bucket, matching the Mac sidebar.
                    hasTitle: !leaf.title.isEmpty
                )))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            if let attentionText = effectiveAttentionText {
                AttentionCapsule(text: attentionText)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
    }
}

/// Red status pill — worktree row uses it for CLI `graftty notify`
/// pings; pane row uses it for shell-integration pings.
private struct AttentionCapsule: View {
    let text: String

    var body: some View {
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

/// `#<number>` PR/MR badge tinted by `PRBadgeStyle.tone`. Tapping
/// opens the PR URL; pulses while CI is pending.
private struct PRBadgeLabel: View {
    let badge: PRBadge
    @Environment(\.openURL) private var openURL

    var body: some View {
        let tone = PRBadgeStyle.tone(
            state: badge.state,
            checks: badge.checks,
            mergeable: badge.mergeable
        )
        Button {
            openURL(badge.url)
        } label: {
            Text("#\(badge.number)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color(for: tone))
                .padding(.horizontal, 3)
                .overlay {
                    if tone == .conflicting {
                        Capsule().strokeBorder(color(for: tone), lineWidth: 1)
                    }
                }
                .opacity(tone.pulses ? 0.5 : 1)
                .animation(
                    tone.pulses
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: tone.pulses
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pull request \(badge.number)")
    }

    private func color(for tone: PRBadgeStyle.Tone) -> Color {
        switch tone {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        case .ciFailure: return .red
        case .ciPending: return .yellow
        case .conflicting: return .red
        }
    }
}

/// Trailing `↑X[+] ↓Y` indicator. Ahead side gets a `+` suffix when
/// there are uncommitted changes so a clean-but-dirty branch still
/// surfaces; behind side renders in red.
private struct DivergenceGutter: View {
    let stats: WorktreeWireStats?
    let theme: GhosttyThemeColors?

    var body: some View {
        if let stats, !stats.isEmpty {
            commitsText(stats)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func commitsText(_ s: WorktreeWireStats) -> Text {
        let aheadShown = s.ahead > 0 || s.hasUncommittedChanges
        let behindShown = s.behind > 0
        // Themed dim when available; nil leaves it on the system label
        // color which the surrounding default-foreground tree already
        // dims for `.foregroundColor(.secondary)` on the compact path.
        let ahead = Text("↑\(s.ahead)\(s.hasUncommittedChanges ? "+" : "")")
            .foregroundColor(theme?.sidebarSecondaryText ?? .secondary)
        let behind = Text("↓\(s.behind)")
            .foregroundColor(.red)
        if aheadShown && behindShown { return ahead + Text(" ") + behind }
        if aheadShown { return ahead }
        return behind
    }
}
#endif

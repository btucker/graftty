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
    public let onSelect: (WorktreePanes) -> Void
    public let onSelectPane: (PaneLayoutNode.Leaf) -> Void
    public let onListChanged: ([WorktreePanes]) -> Void

    public init(
        host: Host,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void,
        onListChanged: @escaping ([WorktreePanes]) -> Void = { _ in }
    ) {
        self.host = host
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
                        Section(repoName) {
                            ForEach(entries, id: \.path) { wt in
                                WorktreeBlock(
                                    worktree: wt,
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
                        }
                    }
                }
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
        .navigationTitle(host.label)
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
        .task { await load() }
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
    let onSelect: () -> Void
    let onSelectPane: (PaneLayoutNode.Leaf) -> Void

    var body: some View {
        if worktree.state.isInFlight {
            // Non-tappable: on-disk path may not exist yet
            // (`.creating`) or is about to vanish (`.deleting`).
            WorktreeRowContent(worktree: worktree)
        } else {
            Button(action: onSelect) {
                WorktreeRowContent(worktree: worktree)
            }
            .buttonStyle(.plain)
        }
        if let layout = worktree.layout {
            // IOS-4.21: pane child rows beneath multi-leaf worktrees are
            // tappable and route straight to the fullscreen terminal,
            // skipping the worktree-detail preview screen. Single-leaf
            // worktrees already shortcut at the worktree row (IOS-4.17),
            // so their pane row stays informational to avoid two tap
            // targets that do the same thing.
            ForEach(layout.leaves, id: \.sessionName) { leaf in
                if layout.isLeaf {
                    PaneTitleRow(leaf: leaf)
                } else {
                    Button { onSelectPane(leaf) } label: {
                        PaneTitleRow(leaf: leaf)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Type icon + optional PR badge + display name (italic for main
/// checkout, strikethrough when stale) + optional secondary branch
/// label + optional attention capsule + trailing divergence gutter.
private struct WorktreeRowContent: View {
    let worktree: WorktreePanes

    var body: some View {
        HStack(spacing: 6) {
            typeIcon
            if let badge = worktree.prBadge {
                PRBadgeLabel(badge: badge)
            }
            primaryText
            if let secondary = secondaryBranch {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let attention = worktree.attentionText {
                AttentionCapsule(text: attention)
            }
            Spacer()
            DivergenceGutter(stats: worktree.stats)
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
            .foregroundStyle(typeIconColor)
            .frame(width: 14)
        }
    }

    /// Dim secondary for closed/creating/deleting, green when running,
    /// yellow when stale.
    private var typeIconColor: Color {
        switch worktree.state {
        case .closed, .creating, .deleting: return .secondary
        case .running: return .green
        case .stale: return .yellow
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        if worktree.state == .stale {
            Text(worktree.displayName)
                .strikethrough()
                .foregroundStyle(.secondary)
        } else if worktree.isMainCheckout {
            Text(worktree.displayName).italic()
        } else {
            Text(worktree.displayName)
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

/// Pane child row: `↳` glyph + caption-sized title (or attention
/// capsule when the pane has a shell-integration ping).
private struct PaneTitleRow: View {
    let leaf: PaneLayoutNode.Leaf

    var body: some View {
        HStack(spacing: 4) {
            Text("↳")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let attentionText = leaf.attentionText {
                AttentionCapsule(text: attentionText)
            } else {
                Text(leaf.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    var body: some View {
        if let stats, !stats.isEmpty {
            commitsText(stats)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func commitsText(_ s: WorktreeWireStats) -> Text {
        let aheadShown = s.ahead > 0 || s.hasUncommittedChanges
        let behindShown = s.behind > 0
        let ahead = Text("↑\(s.ahead)\(s.hasUncommittedChanges ? "+" : "")")
            .foregroundColor(.secondary)
        let behind = Text("↓\(s.behind)")
            .foregroundColor(.red)
        if aheadShown && behindShown { return ahead + Text(" ") + behind }
        if aheadShown { return ahead }
        return behind
    }
}
#endif

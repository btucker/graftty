import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

enum WorktreeStartResult: Equatable {
    case started
    case alreadyRunning
    case notFound
    case unavailable
}

/// Pane and worktree mutations shared by the menu bar, the socket router,
/// remote host channels and libghostty callbacks. Each takes the app state
/// binding and the terminal manager it needs, so tests drive it without
/// the `App`.
@MainActor
enum PaneCommands {
    /// Shared closed-to-running transition used by local sidebar selection
    /// and authenticated remote-open requests.
    static func startWorktree(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        startSurfacesInBackground: Bool = false
    ) -> WorktreeStartResult {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices
            where appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                == path {
                let state = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].state
                guard state != .running else { return .alreadyRunning }
                guard state == .closed else { return .unavailable }

                if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .splitTree.root == nil {
                    let id = PaneSlotID()
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .splitTree = SplitTree(root: .leaf(id))
                }

                let splitTree = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].splitTree
                let leaves = splitTree.allLeaves
                for leafID in leaves {
                    // Stop clears mappings. A retained mapping belongs to a
                    // previous launch and must not replay its default command.
                    // createSurfaces clears this marker if zmx confirms it gone.
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .paneSessions[leafID] != nil {
                        terminalManager.markRehydrated(leafID)
                    }
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .ensurePaneSession(for: leafID)
                }
                // TERM-1.4: a saved multi-pane layout still has only one
                // "first" pane for default-command eligibility. Keep that
                // pane stable even when focus has since moved elsewhere.
                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].normalizeFocusedPane()
                let primaryPane = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                if let primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }
                _ = terminalManager.createSurfaces(
                    for: splitTree,
                    paneSessions: appState.wrappedValue.repos[repoIdx]
                        .worktrees[wtIdx].paneSessions,
                    worktreePath: path
                )
                if startSurfacesInBackground,
                   !terminalManager.startSurfacesForBackgroundLaunch(
                       in: splitTree
                   ) {
                    NSLog(
                        "[Graftty] failed to start one or more background panes for %@",
                        path
                    )
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state =
                    .running
                return .started
            }
        }
        return .notFound
    }

    /// Shared split implementation used by local commands and authenticated
    /// pane-control requests. Remote callers can suppress host focus changes.
    @discardableResult
    static func splitPane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: PaneSlotID,
        split: PaneSplit,
        extraInitialInput: String? = nil,
        activateNewPane: Bool = true,
        preserveZoom: Bool = false,
        reservedSlot: PaneSlotID? = nil,
        reservedSession: PaneSessionID? = nil
    ) -> PaneSlotID? {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let candidate = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard candidate.state == .running,
                      candidate.splitTree.containsLeaf(targetID) else {
                    continue
                }
                // A split never changes which existing pane is primary.
                // Migrate legacy running state before adding a new leaf so
                // Split Left/Up cannot accidentally elect the new pane by
                // tree order.
                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if let primaryPane = wt.primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }

                let direction: SplitDirection = (split == .right || split == .left) ? .horizontal : .vertical
                let newID = reservedSlot ?? PaneSlotID()
                var newTree: SplitTree
                switch split {
                case .right, .down:
                    newTree = wt.splitTree.inserting(newID, at: targetID, direction: direction)
                case .left, .up:
                    newTree = wt.splitTree.insertingBefore(newID, at: targetID, direction: direction)
                }
                if preserveZoom, let zoomed = wt.splitTree.zoomed {
                    newTree = newTree.withZoom(zoomed)
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                if let reservedSession {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].recordPaneSession(reservedSession, for: newID)
                }
                let paneSessionID = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .ensurePaneSession(for: newID)
                // TERM-5.5: createSurface can now fail gracefully
                // (libghostty returned null). Roll back the split-tree
                // mutation so we don't leave a dangling leaf that renders
                // forever as `Color.black + ProgressView`. Returning nil
                // propagates to callers like `addPane` which emit a
                // readable socket `.error`.
                guard terminalManager.createSurface(
                    terminalID: newID,
                    paneSessionID: paneSessionID,
                    worktreePath: wt.path,
                    extraInitialInput: extraInitialInput
                ) != nil else {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = wt.splitTree
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].clearPaneSession(for: newID)
                    terminalManager.discardPaneSessionMetadata(for: newID)
                    return nil
                }
                if activateNewPane {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                        .focusedPaneSlotID = newID
                    terminalManager.setFocus(newID)
                }
                return newID
            }
        }
        return nil
    }

    /// Find the worktree that owns `terminalID` and set the attention
    /// badge on *that specific pane*. The shell-integration event that
    /// drives this callback (`COMMAND_FINISHED`) is emitted by one
    /// concrete pane, so the badge belongs on its row and nobody else's —
    /// writing to the worktree-level `attention` slot would light up
    /// every sibling pane in the sidebar. No-op if the terminal isn't
    /// in any worktree (e.g., it was just destroyed). Auto-clears after
    /// `clearAfter` seconds.
    static func setAttentionForTerminal(
        appState: Binding<AppState>,
        terminalID: PaneSlotID,
        text: String,
        clearAfter: TimeInterval,
        source: AttentionSource
    ) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        // Pin a single Date so the stored attention AND the closure
        // share the same generation token (same shape as the
        // worktree-scoped `AttentionAutoClear` in ControlRequestCore). The closure
        // checks current timestamp == captured before clearing, so a
        // newer ping or an explicit clear that lands between the
        // schedule and the fire can't be wiped.
        let stamp = Date()
        var path: String?
        appState.wrappedValue.mutateWorktree(containing: terminalID) { worktree in
            worktree.setAttention(
                Attention(text: text, timestamp: stamp, clearAfter: clearAfter, source: source),
                pane: terminalID
            )
            path = worktree.path
        }
        if let path {
            AttentionAutoClear.schedule(
                after: clearAfter,
                appState: appState,
                worktreePath: path,
                pane: terminalID,
                stamp: stamp
            )
        }
    }

    /// Move a pane to the worktree whose path is the longest prefix of
    /// `newPWD`. No-op when `newPWD` matches no worktree, or matches the
    /// pane's current home.
    static func reassignPaneByPWD(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        terminalID: PaneSlotID,
        newPWD: String
    ) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        // Find the currently-hosting worktree (by scanning splitTrees) so
        // we can compare against the target worktree and short-circuit if
        // nothing has changed.
        var currentRepoIdx: Int?
        var currentWorktreeIdx: Int?
        for (ri, repo) in appState.wrappedValue.repos.enumerated() {
            for (wi, wt) in repo.worktrees.enumerated() where wt.splitTree.containsLeaf(terminalID) {
                currentRepoIdx = ri
                currentWorktreeIdx = wi
            }
        }
        guard let currentRepoIdx, let currentWorktreeIdx else { return }
        // Directory changes do not transfer an assignment or its parent binding.
        guard !appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
            .ownsManagedAgent(in: terminalID) else { return }

        // Longest-prefix match across every repo (handles nested worktrees:
        // a linked worktree at `/r/wt/feature` beats the main checkout at
        // `/r`). `AppState.worktreeIndicesMatching` is the single source
        // of truth — also called by the sidebar menu's auto-detect label.
        guard let (targetRepoIdx, targetWorktreeIdx) =
                appState.wrappedValue.worktreeIndicesMatching(path: newPWD),
              (targetRepoIdx, targetWorktreeIdx) != (currentRepoIdx, currentWorktreeIdx)
        else { return }

        guard terminalManager.wakeWorktree(appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].path),
              terminalManager.wakeWorktree(appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].path)
        else { return }

        // Remember where this pane was sitting in the source tree *before*
        // we remove it, so a later return trip can land it in (roughly)
        // the same spot.
        _ = appState.wrappedValue.repos[currentRepoIdx]
            .worktrees[currentWorktreeIdx].ensurePrimaryPane()
        let sourceWt = appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
        terminalManager.rememberPosition(
            terminalID: terminalID,
            worktreePath: sourceWt.path,
            in: sourceWt.splitTree
        )

        // Remove from source tree; if the source becomes empty, transition
        // its worktree back to .closed so the sidebar reflects that no
        // panes live there anymore.
        let sourceTree = sourceWt.splitTree.removing(terminalID)
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].splitTree = sourceTree
        // Drop any pane-scoped attention badge attached to the moving
        // pane. The ping was tied to the source-worktree context; the
        // target worktree has its own separate attention state.
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
            .paneAttention[terminalID] = nil
        var sessionSource = appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx]
        var sessionTarget = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx]
        _ = sessionSource.movePaneSession(for: terminalID, to: &sessionTarget)
        appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].paneSessions =
            sessionSource.paneSessions
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].paneSessions =
            sessionTarget.paneSessions
        if sourceTree.root == nil {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].state = .closed
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedPaneSlotID = nil
        } else {
            appState.wrappedValue.repos[currentRepoIdx].worktrees[currentWorktreeIdx].focusedPaneSlotID =
                SplitTree.focusAfterRemoving(
                    currentFocus: sourceWt.focusedPaneSlotID,
                    removed: terminalID,
                    remainingTree: sourceTree
                )
        }
        // Preserve the source's primary pane unless that was the pane that
        // moved. If it was, persist the focused survivor (or first leaf) as
        // the replacement; an empty source clears the primary.
        let replacementSourcePrimary = appState.wrappedValue.repos[currentRepoIdx]
            .worktrees[currentWorktreeIdx].ensurePrimaryPane()

        // Graft onto the target tree. Prefer a previously-remembered
        // position (pane is returning to a worktree it once occupied); if
        // the anchor from that memory is still present, reinsert there so
        // the layout feels like the pane "came back to its seat." Fall
        // back to inserting at an arbitrary leaf when no usable
        // breadcrumb exists.
        // Migrate an existing target's primary before inserting the moving
        // pane. Otherwise a left/top insertion could become primary merely
        // because it moved to the front of tree order.
        _ = appState.wrappedValue.repos[targetRepoIdx]
            .worktrees[targetWorktreeIdx].ensurePrimaryPane()
        let targetWt = appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx]
        let targetTree: SplitTree
        let remembered = terminalManager.rememberedPosition(
            terminalID: terminalID,
            worktreePath: targetWt.path
        )
        if let remembered, targetWt.splitTree.containsLeaf(remembered.anchorID) {
            switch remembered.placement {
            case .before:
                targetTree = targetWt.splitTree.insertingBefore(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            case .after:
                targetTree = targetWt.splitTree.inserting(
                    terminalID,
                    at: remembered.anchorID,
                    direction: remembered.direction
                )
            }
            terminalManager.forgetPosition(terminalID: terminalID, worktreePath: targetWt.path)
        } else if let anchor = targetWt.splitTree.allLeaves.first {
            targetTree = targetWt.splitTree.inserting(terminalID, at: anchor, direction: .horizontal)
        } else {
            targetTree = SplitTree(root: .leaf(terminalID))
        }
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].splitTree = targetTree
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].state = .running
        appState.wrappedValue.repos[targetRepoIdx].worktrees[targetWorktreeIdx].focusedPaneSlotID = terminalID
        let targetPrimary = appState.wrappedValue.repos[targetRepoIdx]
            .worktrees[targetWorktreeIdx].ensurePrimaryPane()
        // PaneSlotIDs are globally unique, so moving a pane can safely
        // clear its source marker before applying both worktrees' current
        // primary ownership. This also handles an empty target electing
        // the moved pane.
        terminalManager.unmarkFirstPane(terminalID)
        if let replacementSourcePrimary {
            terminalManager.markFirstPane(replacementSourcePrimary)
        }
        if let targetPrimary {
            terminalManager.markFirstPane(targetPrimary)
        }
        let targetPath = targetWt.path
        if let paneSession = sessionTarget.paneSessions[terminalID] {
            terminalManager.recordPaneSession(
                paneSession,
                for: terminalID,
                worktreePath: targetPath
            )
        }

        // Follow the pane with the UI ONLY when the reassigned pane was the
        // user's active typing target — i.e. the focused pane of the
        // currently-selected worktree. `PWDReassignmentPolicy` encodes the
        // decision. Unconditionally switching selection used to hijack the
        // user's view whenever ANY background pane `cd`'d across a
        // worktree boundary — Andy's 3–6 concurrent Claude-session setup
        // made that immediately pathological. `PWD-2.3` (revised).
        let follow = PWDReassignmentPolicy.shouldFollowToDestination(
            selectedWorktreePath: appState.wrappedValue.selectedWorktreePath,
            sourceWorktreePath: sourceWt.path,
            sourceFocusedPaneSlotID: sourceWt.focusedPaneSlotID,
            reassignedPaneSlotID: terminalID
        )
        if follow {
            appState.wrappedValue.selectedWorktreePath = targetPath
            terminalManager.setFocus(terminalID)
        }
    }

    /// Static navigate used by the `onGotoSplit` callback (triggered from
    /// libghostty keybinds). Uses `SplitTree.spatialNeighbor` (`TERM-7.3`)
    /// so `.down` genuinely means "the pane spatially below," not "the
    /// next leaf in DFS order." When there is no neighbor in the requested
    /// direction the keypress is ignored — matching upstream Ghostty and
    /// terminal multiplexers like tmux, which leave focus put rather than
    /// wrapping to an unrelated pane.
    static func navigatePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: PaneSlotID,
        direction: NavigationDirection
    ) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.splitTree.containsLeaf(terminalID) else { continue }
                guard let nextID = wt.navigationTree.spatialNeighbor(
                    of: terminalID,
                    direction: direction.asSpatial
                ) else {
                    // No spatial neighbor — no-op, focus stays where it is.
                    return
                }
                // Zoom preservation: Ghostty 1.3 `split-preserve-zoom = navigation` opt-in.
                if wt.splitTree.zoomed != nil {
                    let newTree = terminalManager.splitPreserveZoomOnNavigation
                        ? wt.splitTree.withZoom(nextID)
                        : wt.splitTree.withZoom(nil)
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }

    /// `Previous Pane` / `Next Pane` cycle through the worktree's leaves in
    /// DFS order regardless of the spatial layout — that's what the menu
    /// items promise. Kept separate from the spatial `navigatePane` so
    /// TERM-7.3 (arrow-key spatial nav) doesn't silently change the
    /// round-robin semantics shared by fixed and host tab-action chords.
    static func navigatePaneInTreeOrder(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        from terminalID: PaneSlotID,
        forward: Bool
    ) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                let leaves = wt.splitTree.allLeaves
                guard let currentIdx = leaves.firstIndex(of: terminalID) else { continue }
                guard leaves.count > 1 else { return }
                let nextIdx = forward
                    ? (currentIdx + 1) % leaves.count
                    : (currentIdx - 1 + leaves.count) % leaves.count
                let nextID = leaves[nextIdx]
                if wt.splitTree.zoomed != nil {
                    let newTree = terminalManager.splitPreserveZoomOnNavigation
                        ? wt.splitTree.withZoom(nextID)
                        : wt.splitTree.withZoom(nil)
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }

    static func toggleZoom(appState: Binding<AppState>, on terminalID: PaneSlotID) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        appState.wrappedValue.mutateWorktree(containing: terminalID) { wt in
            guard (wt.workspaceLayout?.visibleSplitTree ?? wt.splitTree).containsLeaf(terminalID) else {
                wt.splitTree = wt.splitTree.withZoom(nil)
                return
            }
            wt.splitTree = wt.splitTree.togglingZoom(at: terminalID)
        }
    }

    static func equalizeSplits(
        appState: Binding<AppState>,
        around terminalID: PaneSlotID,
        preserveZoom: Bool = false
    ) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        appState.wrappedValue.mutateWorktree(containing: terminalID) { wt in
            let zoomed = wt.splitTree.zoomed
            wt.splitTree = wt.splitTree.equalizing()
            if let layout = wt.workspaceLayout { wt.workspaceLayout?.updateGeometry(from: layout.visibleSplitTree.equalizing()) }
            if preserveZoom, let zoomed {
                wt.splitTree = wt.splitTree.withZoom(zoomed)
            }
        }
    }

    @discardableResult
    static func resizeSplit(
        appState: Binding<AppState>,
        target: PaneSlotID,
        direction: ResizeDirection,
        pixels: UInt16,
        ancestorBounds: CGRect? = nil,
        preserveZoom: Bool = false
    ) -> Bool {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        // MVP: use the key window's content-area bounds as a proxy for the
        // ancestor split bounds. Accurate for single-split layouts; for nested
        // splits the delta will be slightly off. A follow-up can capture
        // per-split bounds via SwiftUI preference keys.
        // TODO: plumb per-split GeometryReader bounds for multi-level accuracy.
        let bounds = ancestorBounds
            ?? NSApp.keyWindow?.contentView?.bounds
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        var didResize = false
        appState.wrappedValue.mutateWorktree(containing: target) { wt in
            do {
                let zoomed = wt.splitTree.zoomed
                if let layout = wt.workspaceLayout, layout.group(containing: target) != nil {
                    let resized = try layout.visibleSplitTree.resizing(target: target, direction: direction, pixels: pixels, ancestorBounds: bounds)
                    wt.workspaceLayout?.updateGeometry(from: resized)
                    wt.splitTree = wt.splitTree.withZoom(preserveZoom ? zoomed : nil)
                    didResize = true
                    return
                }
                wt.splitTree = try wt.splitTree.resizing(
                    target: target,
                    direction: direction,
                    pixels: pixels,
                    ancestorBounds: bounds
                )
                if preserveZoom, let zoomed {
                    wt.splitTree = wt.splitTree.withZoom(zoomed)
                }
                didResize = true
            } catch {
                // No matching orientation ancestor — silent no-op, matches Ghostty.
            }
        }
        return didResize
    }

    /// Shared close-pane implementation used by Cmd+W and libghostty's
    /// `close_surface_cb` (shell exit). Removes the pane from its worktree's
    /// split tree, destroys the surface, promotes focus to a sibling, and
    /// transitions the worktree to `.closed` when the last pane goes away.
    /// Idempotent: no-op if the terminal isn't in any tree.
    ///
    /// `userInitiated`: distinguishes Cmd+W / CLI / context-menu close
    /// (`true`) from libghostty's async `close_surface_cb` (`false`).
    /// `PhantomPaneClosePolicy.shouldRemoveFromTree` uses this to let
    /// user-initiated closes clean up phantom leaves (surface creation
    /// failed, `TERM-5.8`) while keeping the `TERM-5.7` Stop-cascade guard
    /// for libghostty-initiated callbacks.
    static func closePane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: PaneSlotID,
        userInitiated: Bool = false,
        activateReplacement: Bool = true
    ) {
        if terminalManager.managedPaneClose?(targetID, userInitiated) == true { return }
        removeEndedPane(appState: appState, terminalManager: terminalManager, targetID: targetID,
            userInitiated: userInitiated, activateReplacement: activateReplacement)
    }

    static func removeEndedPane(appState: Binding<AppState>, terminalManager: TerminalManager,
                                targetID: PaneSlotID, userInitiated: Bool = true,
                                activateReplacement: Bool = true) {
        let before = appState.wrappedValue
        defer { GrafttyApp.persistAppStateIfChanged(appState, from: before) }
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let candidate = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard candidate.splitTree.containsLeaf(targetID) else { continue }

                // TERM-5.7 (Stop cascade) vs TERM-5.8 (phantom leaf).
                // `handle == nil` can mean either:
                //   * destroySurface just ran during Stop and the late
                //     close_surface_cb arrived with splitTree preserved
                //     per TERM-1.2 → leave it alone, or
                //   * the surface never instantiated at all (libghostty
                //     OOM, TERM-5.5) → the user's Cmd+W / CLI close is
                //     their ONLY way to remove the phantom leaf.
                // The caller tells us which by `userInitiated`.
                guard PhantomPaneClosePolicy.shouldRemoveFromTree(
                    userInitiated: userInitiated,
                    handleExists: terminalManager.handle(for: targetID) != nil
                ) else { continue }

                _ = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .recordManagedSessionEnd(slot: targetID, reason: "Terminal session ended")
                terminalManager.destroySurface(terminalID: targetID)
                let newTree = wt.splitTree.removing(targetID)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                // Drop any lingering per-pane attention so a destroyed
                // terminal doesn't leak a badge entry into the model.
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .paneAttention[targetID] = nil
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                    .clearPaneSession(for: targetID)

                if newTree.root == nil {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .closed
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = nil
                } else {
                    // TERM-5.6: only promote focus when the CLOSED pane
                    // was the focused one. Pre-fix, this branch always
                    // reassigned focus to `newTree.allLeaves.first`,
                    // silently jumping focus away from whatever pane the
                    // user was typing in if they closed a different pane.
                    let previousFocus = wt.focusedPaneSlotID
                    let newFocus = SplitTree.focusAfterRemoving(
                        currentFocus: previousFocus,
                        removed: targetID,
                        remainingTree: newTree
                    )
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = newFocus
                    // Only push focus to libghostty if it actually
                    // changed — otherwise we're re-raising the same
                    // surface for no reason.
                    if activateReplacement,
                       let newFocus,
                       newFocus != previousFocus {
                        terminalManager.setFocus(newFocus)
                    }
                }
                // Closing a non-primary pane preserves startup ownership.
                // Closing the primary elects and persists a survivor.
                let primaryPane = appState.wrappedValue.repos[repoIdx]
                    .worktrees[wtIdx].ensurePrimaryPane()
                if let primaryPane {
                    terminalManager.markFirstPane(primaryPane)
                }
                return
            }
        }
    }

}

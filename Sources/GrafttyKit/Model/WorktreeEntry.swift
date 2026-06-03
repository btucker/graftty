import Foundation
import GrafttyProtocol

public enum WorktreeState: String, Codable, Sendable {
    case closed
    case running
    case stale
    /// Placeholder shown in the sidebar between the user submitting the
    /// Add Worktree sheet and `git worktree add` returning. Only ever
    /// produced by `AddWorktreeFlow`; the row renders a spinner in place
    /// of its type icon and suppresses pane rows / context-menu actions
    /// while the git invocation (and any pre-commit / post-checkout
    /// hooks) is running. Transient by design — see custom `encode` for
    /// the persistence policy.
    case creating
    /// Placeholder shown while `DeleteWorktreeFlow` is mid-`git worktree
    /// remove`. Only ever produced by that flow. Transient by design —
    /// see custom `encode` for the persistence policy.
    case deleting

    /// `.creating` / `.deleting` are in-memory only. If the app crashes
    /// mid-flight, the on-disk worktree may or may not exist — the next
    /// launch's reconciler will resolve it (see `GIT-2.2`). Persisting
    /// either transient state would otherwise leave a phantom row
    /// spinning forever after restart, so we coerce both to `.closed` on
    /// encode and let the reconciler classify based on `git worktree
    /// list --porcelain`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .creating, .deleting: try container.encode(WorktreeState.closed.rawValue)
        case .closed, .running, .stale: try container.encode(self.rawValue)
        }
    }

    /// True iff the entry's path corresponds to an actual on-disk
    /// worktree git can inspect. Polling stores (stats, PR), per-
    /// worktree subprocess scans, and FSEvents watcher arming should
    /// gate on this — `.creating` placeholders have no directory yet,
    /// `.stale` placeholders have lost theirs, and `.deleting` rows are
    /// about to lose theirs; firing fresh subprocesses against any of
    /// them is wasted work at best, racey at worst.
    public var hasOnDiskWorktree: Bool {
        switch self {
        case .closed, .running: return true
        case .stale, .creating, .deleting: return false
        }
    }

    /// True iff the entry is a transient placeholder owned by a flow
    /// (`AddWorktreeFlow` for `.creating`, `DeleteWorktreeFlow` for
    /// `.deleting`). The on-disk path is either not there yet or
    /// about to vanish — every consumer that touches the path or the
    /// row's interactivity gates on this so it doesn't race the flow.
    public var isInFlight: Bool {
        self == .creating || self == .deleting
    }

    /// Cross-platform projection used by shared sidebar accessors
    /// (e.g. `GhosttyThemeColors.worktreeStateIcon`). The Mac enum and
    /// the wire enum carry identical cases and raw values; the bridge
    /// is total via the shared `String` raw values.
    public var wireState: WorktreeWireState {
        WorktreeWireState(rawValue: rawValue) ?? .closed
    }
}

public struct WorktreeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The worktree's absolute path on disk. Mutable so the relocate
    /// cascade (LAYOUT-4.8) can rewrite it when a repo folder is renamed
    /// or moved in Finder — carrying forward `id` / `splitTree` / state
    /// fields while the containing repo moves to a new prefix. Outside
    /// the relocate cascade, callers treat this as write-once.
    public var path: String
    public var branch: String
    public var state: WorktreeState
    /// Worktree-scoped attention slot. Driven by the CLI
    /// (`graftty notify`), which targets a worktree path rather than a
    /// specific pane. Rendered on the worktree's own sidebar row
    /// (STATE-2.3), independent of the pane rows beneath it.
    public var attention: Attention?
    /// Pane-scoped attention slots keyed by pane `PaneSlotID`. Driven by
    /// shell-integration events (`COMMAND_FINISHED`) that are emitted by
    /// one specific pane — so the ping must land on that pane's sidebar
    /// row and leave its siblings untouched. The two scopes render in
    /// different rows and do not fall back onto one another.
    public var paneAttention: [PaneSlotID: Attention]
    public var paneSessions: [PaneSlotID: PaneSessionID]
    public var splitTree: SplitTree
    public var focusedPaneSlotID: PaneSlotID?
    /// PR number for which the "PR resolved — delete worktree?" offer
    /// dialog has already been presented (the PR has either merged or
    /// been closed without merging — GIT-4.7). Persisted so that a
    /// force-push that closes PR N and reopens as PR M is correctly
    /// treated as a fresh transition (the numbers differ), while a
    /// steady poll of the same resolved PR stays quiet.
    public var offeredDeleteForResolvedPR: Int?

    public init(
        path: String,
        branch: String,
        state: WorktreeState = .closed,
        attention: Attention? = nil,
        splitTree: SplitTree = SplitTree(root: nil)
    ) {
        self.id = UUID()
        self.path = path
        self.branch = branch
        self.state = state
        self.attention = attention
        self.paneAttention = [:]
        self.paneSessions = [:]
        self.splitTree = splitTree
        self.focusedPaneSlotID = nil
        self.offeredDeleteForResolvedPR = nil
    }

    // Custom Decodable so `paneAttention`, `paneSessions`, and
    // `offeredDeleteForResolvedPR` (added after the initial release) are
    // optional on disk. Pre-fix
    // persisted blobs don't carry those keys; defaulting lets existing
    // users keep their saved split trees across upgrades rather than
    // failing to decode and silently losing everything.
    private enum CodingKeys: String, CodingKey {
        case id, path, branch, state, attention, paneAttention,
             paneSessions, splitTree, offeredDeleteForResolvedPR
        case focusedPaneSlotID = "focusedTerminalID"
    }

    /// Legacy key honored on decode only — state blobs persisted by
    /// the build that knew only `.merged` PRs (before GIT-4.7 broadened
    /// to include closed-without-merging) carry this name. Read in
    /// `init(from:)` as a fallback so users upgrading from that build
    /// don't get re-prompted for merged PRs they've already dismissed.
    private enum LegacyCodingKeys: String, CodingKey {
        case offeredDeleteForMergedPR
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.branch = try container.decode(String.self, forKey: .branch)
        self.state = try container.decode(WorktreeState.self, forKey: .state)
        self.attention = try container.decodeIfPresent(Attention.self, forKey: .attention)
        self.paneAttention = try container.decodeIfPresent(
            [PaneSlotID: Attention].self,
            forKey: .paneAttention
        ) ?? [:]
        self.paneSessions = try container.decodeIfPresent(
            [PaneSlotID: PaneSessionID].self,
            forKey: .paneSessions
        ) ?? [:]
        self.splitTree = try container.decode(SplitTree.self, forKey: .splitTree)
        self.focusedPaneSlotID = try container.decodeIfPresent(
            PaneSlotID.self,
            forKey: .focusedPaneSlotID
        )
        let resolved = try container.decodeIfPresent(
            Int.self, forKey: .offeredDeleteForResolvedPR
        )
        let legacyMerged = try decoder.container(keyedBy: LegacyCodingKeys.self)
            .decodeIfPresent(Int.self, forKey: .offeredDeleteForMergedPR)
        self.offeredDeleteForResolvedPR = resolved ?? legacyMerged
    }

    /// Single setter for attention: pane-scoped when `pane` is non-nil,
    /// worktree-scoped otherwise. All three sources (agent-stop, user
    /// notify, command-finished) route through here so the scoping rule
    /// lives in one place.
    public mutating func setAttention(_ attention: Attention, pane: PaneSlotID?) {
        if let pane {
            paneAttention[pane] = attention
        } else {
            self.attention = attention
        }
    }

    /// The user is now looking at this worktree (sidebar click or
    /// notification activation): clear ALL attention — worktree-scoped and
    /// every pane (STATE-2.4). One method so both acknowledgement paths
    /// can't drift on scope.
    public mutating func acknowledgeAttention() {
        attention = nil
        paneAttention.removeAll()
    }

    /// @spec AGENT-3.4
    /// An agent resumed work in one of `busy`'s sessions, so it no longer
    /// needs input: clear only `.agentStop` attention (pane-scoped for the
    /// matching busy pane, and worktree-scoped when any of this worktree's
    /// sessions is busy). `.userNotify` and `.commandFinished` overlays are
    /// deliberately left alone.
    public mutating func clearAgentStopAttention(forBusySessionNames busy: Set<String>) {
        guard !busy.isEmpty else { return }
        for (slot, session) in paneSessions
        where paneAttention[slot]?.source == .agentStop
            && busy.contains(ZmxLauncher.sessionName(for: session)) {
            paneAttention[slot] = nil
        }
        if attention?.source == .agentStop,
           paneSessions.values.contains(where: { busy.contains(ZmxLauncher.sessionName(for: $0)) }) {
            attention = nil
        }
    }

    /// Clears the worktree-scoped attention overlay iff it still has the
    /// given `timestamp`. Used by the auto-clear timer scheduled for a
    /// `--clear-after` notification: if the attention has been replaced
    /// by a newer `notify` in the meantime, or cleared manually, the
    /// pending timer must leave the current state alone.
    public mutating func clearAttentionIfTimestamp(_ timestamp: Date) {
        if attention?.timestamp == timestamp {
            attention = nil
        }
    }

    /// Clears the pane-scoped attention overlay for `terminalID` iff it
    /// still has the given `timestamp`. Same STATE-2.6 invariant as
    /// `clearAttentionIfTimestamp`, applied to shell-integration pings
    /// (`COMMAND_FINISHED` events) that target a specific pane rather
    /// than the worktree slot.
    public mutating func clearPaneAttentionIfTimestamp(
        _ timestamp: Date,
        for terminalID: PaneSlotID
    ) {
        if paneAttention[terminalID]?.timestamp == timestamp {
            paneAttention[terminalID] = nil
        }
    }

    @discardableResult
    public mutating func ensurePaneSession(for slot: PaneSlotID) -> PaneSessionID {
        if let existing = paneSessions[slot] {
            return existing
        }

        let session = PaneSessionID()
        paneSessions[slot] = session
        return session
    }

    public mutating func ensurePaneSessionsForRunningRestore() {
        guard state == .running else { return }

        for slot in splitTree.allLeaves where paneSessions[slot] == nil {
            paneSessions[slot] = .migratedFromLegacySlot(slot)
        }
    }

    public mutating func clearPaneSession(for slot: PaneSlotID) {
        paneSessions[slot] = nil
    }

    @discardableResult
    public mutating func takePaneSession(for slot: PaneSlotID) -> PaneSessionID? {
        paneSessions.removeValue(forKey: slot)
    }

    public mutating func recordPaneSession(_ session: PaneSessionID, for slot: PaneSlotID) {
        paneSessions[slot] = session
    }

    @discardableResult
    public mutating func movePaneSession(
        for slot: PaneSlotID,
        to target: inout WorktreeEntry
    ) -> PaneSessionID? {
        guard let session = takePaneSession(for: slot) else { return nil }
        target.recordPaneSession(session, for: slot)
        return session
    }

    public mutating func clearAllPaneSessions() {
        paneSessions.removeAll()
    }

    /// Inverts `paneSessions` to find the pane slot whose zmx session name
    /// matches `sessionName` (the `ZMX_SESSION` an agent inherited). Shared
    /// by busy/idle rendering, agent-stop attribution, and `notify --session`.
    public func paneSlot(forSessionName sessionName: String) -> PaneSlotID? {
        for (slot, paneSession) in paneSessions
        where ZmxLauncher.sessionName(for: paneSession) == sessionName {
            return slot
        }
        return nil
    }

    /// Transitions this entry from `.stale` back to `.closed`, returning
    /// the list of leaf `PaneSlotID`s whose surfaces the caller MUST
    /// destroy via `TerminalManager.destroySurfaces(terminalIDs:)` before
    /// the UI re-creates the worktree (`GIT-3.9`).
    ///
    /// When a worktree went stale *while running* (`GIT-3.4` keeps its
    /// Ghostty surfaces alive across the stale transition), those
    /// surfaces are still registered in `TerminalManager`. The resurrect
    /// path then creates a *new* `PaneSlotID` and a *new* surface, which
    /// leaves the old surfaces orphan: their render/io/kqueue threads
    /// keep running forever. On macOS this has been observed to corrupt
    /// libghostty's internal `os_unfair_lock` during window resize and
    /// SIGKILL the app.
    ///
    /// Returning the old leaves from the same mutation that clears
    /// `splitTree` forces the caller to either destroy them or
    /// deliberately drop them — silently clearing the tree in-place (the
    /// pre-`GIT-3.9` shape) is no longer spellable from the outside.
    @discardableResult
    public mutating func prepareForResurrection() -> [PaneSlotID] {
        let oldLeaves = splitTree.allLeaves
        state = .closed
        splitTree = SplitTree(root: nil)
        focusedPaneSlotID = nil
        paneAttention.removeAll()
        clearAllPaneSessions()
        return oldLeaves
    }

    /// Returns the leaf `PaneSlotID`s whose surfaces the caller MUST
    /// destroy via `TerminalManager.destroySurfaces(terminalIDs:)` before
    /// removing this entry from the model (`GIT-3.10`). Same orphan-
    /// surfaces concern as `prepareForResurrection` (`GIT-3.9`), but via
    /// the Dismiss path instead of the resurrect path.
    ///
    /// `GIT-3.4` keeps terminal surfaces alive when a worktree goes
    /// stale-while-running. Dismiss (`GIT-3.6`) then removes the entry
    /// from the sidebar — but if the caller forgets to tear the
    /// surfaces down, their render/IO/kqueue threads keep running
    /// forever. Same corruption path that SIGKILL'd the app under
    /// window resize pre-`GIT-3.9`.
    ///
    /// Clearing `splitTree` / `focusedPaneSlotID` / `paneAttention`
    /// here is largely symbolic since the caller is about to drop the
    /// whole entry, but it ensures a caller that ignores the return
    /// value leaves a visibly-empty entry rather than a sidebar row
    /// that still looks populated.
    @discardableResult
    public mutating func prepareForDismissal() -> [PaneSlotID] {
        let leaves = splitTree.allLeaves
        splitTree = SplitTree(root: nil)
        focusedPaneSlotID = nil
        paneAttention.removeAll()
        clearAllPaneSessions()
        return leaves
    }

    /// Transitions the entry from `.running` to `.closed` as part of the
    /// Stop menu action, dropping `paneAttention` for every pane (all
    /// panes are being destroyed; their pane-scoped badges must go per
    /// `STATE-2.11`). Leaves `splitTree` and `focusedPaneSlotID` alone
    /// so re-open recreates the exact same layout at the same leaf IDs
    /// (`TERM-1.2`), and leaves the worktree-level `attention` slot
    /// alone since a CLI-notify ping is a worktree-level concern
    /// independent of which panes are alive.
    public mutating func prepareForStop() {
        state = .closed
        paneAttention.removeAll()
        clearAllPaneSessions()
    }

    /// User-facing label for the worktree *in the context of its siblings*.
    ///
    /// Common case: the directory name the user picked when running
    /// `git worktree add ../<name>` is unique and informative, so we show
    /// the last path component.
    ///
    /// Collision case: when two worktrees of the same repo share a last
    /// component (e.g. `/Users/ben/projects/blindspots` AND
    /// `/Users/ben/.codex/worktrees/6750/blindspots` — common with tools
    /// that auto-create worktrees in namespaced directories), the label
    /// would be ambiguous. Grow the suffix one component at a time until
    /// it's unique among siblings. LAYOUT-2.15: this recurses — the
    /// pre-fix 1-level version stopped at `parent/last` and still
    /// collided for layouts like `<root>/.worktrees/<ns>/<ns>/feature`
    /// sharing both leaf and immediate parent. Falls back to the full
    /// path when no suffix length produces a unique candidate (e.g. one
    /// sibling's path is a strict suffix of another's).
    ///
    /// `siblingPaths` must include this worktree's own path; everything
    /// else is compared against the self candidate of the same depth.
    public func displayName(amongSiblingPaths siblingPaths: [String]) -> String {
        let selfComponents = WorktreeEntry.significantComponents(path)
        let fallback: String = selfComponents.last ?? branch

        let othersComponents = siblingPaths
            .filter { $0 != path }
            .map(WorktreeEntry.significantComponents)

        guard !selfComponents.isEmpty else { return fallback }

        for suffixLen in 1...selfComponents.count {
            let candidate = selfComponents.suffix(suffixLen).joined(separator: "/")
            let collides = othersComponents.contains { other in
                // Sibling must have at least as many components to produce
                // the same candidate; shorter siblings with the same
                // suffix CAN'T match at this depth.
                other.count >= suffixLen
                    && other.suffix(suffixLen).joined(separator: "/") == candidate
            }
            if !collides { return candidate }
        }
        // Exhausted: no suffix is unique. Could happen if a sibling's
        // full path equals ours (git prevents this) OR if one sibling's
        // path is strictly contained in another. Fall back to the full
        // path so SOMETHING distinguishes them.
        return path
    }

    /// Path split into components with `/` (root separator) dropped,
    /// matching NSString.pathComponents semantics minus the leading `/`
    /// entry. An empty input produces an empty array.
    private static func significantComponents(_ path: String) -> [String] {
        (path as NSString).pathComponents.filter { $0 != "/" }
    }

    /// @spec GIT-2.10
    /// When the application renders a worktree's branch name in the UI
    /// (the breadcrumb bar per `LAYOUT-1.3` and the secondary dimmed
    /// caption in the sidebar row), it shall read this property rather
    /// than `WorktreeEntry.branch`. `displayBranch` strips every Unicode
    /// bidirectional-override scalar (same ranges as `PR-5.5`) so a
    /// collaborator-controlled branch name like `"feat\u{202E}lanigiro"`
    /// — which git accepts and which propagates into `state.json` via
    /// `git worktree list --porcelain` — can't render RTL-reversed in
    /// the breadcrumb or row. `branch` itself is preserved unchanged so
    /// downstream `git` subprocess calls, `gh pr list --head <branch>`,
    /// and the `PRStatusStore.isFetchableBranch` gate keep operating on
    /// the real ref. This is the same strip-not-reject policy `PR-5.5`
    /// uses for externally-sourced text.
    public var displayBranch: String {
        BidiOverrides.stripping(branch)
    }
}

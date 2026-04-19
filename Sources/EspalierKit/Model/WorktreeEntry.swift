import Foundation

public enum WorktreeState: String, Codable, Sendable {
    case closed
    case running
    case stale
}

public struct WorktreeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var branch: String
    public var state: WorktreeState
    /// Worktree-scoped attention slot. Driven by the CLI
    /// (`espalier notify`), which targets a worktree path rather than a
    /// specific pane. Rendered on pane rows that don't have their own
    /// `paneAttention[terminalID]` entry.
    public var attention: Attention?
    /// Pane-scoped attention slots keyed by pane `TerminalID`. Driven by
    /// shell-integration events (`COMMAND_FINISHED`) that are emitted by
    /// one specific pane — so the ping must land on that pane's sidebar
    /// row and leave its siblings untouched. A pane's entry wins over
    /// the worktree-level `attention` slot when rendering that pane's
    /// row, but the worktree slot stays available as a fallback for
    /// other panes (and for the CLI path).
    public var paneAttention: [TerminalID: Attention]
    public var splitTree: SplitTree
    public var focusedTerminalID: TerminalID?
    /// PR number for which the "PR merged — delete worktree?" offer
    /// dialog has already been presented. Persisted so that a force-push
    /// that closes PR N and reopens as PR M is correctly treated as a
    /// fresh transition (the numbers differ), while a steady poll of
    /// the same merged PR stays quiet.
    public var offeredDeleteForMergedPR: Int?

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
        self.splitTree = splitTree
        self.focusedTerminalID = nil
        self.offeredDeleteForMergedPR = nil
    }

    // Custom Decodable so `paneAttention` and `offeredDeleteForMergedPR`
    // (both added after the initial release) are optional on disk.
    // Pre-fix persisted state blobs don't carry those keys; defaulting
    // lets existing users keep their saved split trees across upgrades
    // rather than failing to decode and silently losing everything.
    private enum CodingKeys: String, CodingKey {
        case id, path, branch, state, attention, paneAttention,
             splitTree, focusedTerminalID, offeredDeleteForMergedPR
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.branch = try container.decode(String.self, forKey: .branch)
        self.state = try container.decode(WorktreeState.self, forKey: .state)
        self.attention = try container.decodeIfPresent(Attention.self, forKey: .attention)
        self.paneAttention = try container.decodeIfPresent(
            [TerminalID: Attention].self,
            forKey: .paneAttention
        ) ?? [:]
        self.splitTree = try container.decode(SplitTree.self, forKey: .splitTree)
        self.focusedTerminalID = try container.decodeIfPresent(
            TerminalID.self,
            forKey: .focusedTerminalID
        )
        self.offeredDeleteForMergedPR = try container.decodeIfPresent(
            Int.self,
            forKey: .offeredDeleteForMergedPR
        )
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
        for terminalID: TerminalID
    ) {
        if paneAttention[terminalID]?.timestamp == timestamp {
            paneAttention[terminalID] = nil
        }
    }

    /// Transitions this entry from `.stale` back to `.closed`, returning
    /// the list of leaf `TerminalID`s whose surfaces the caller MUST
    /// destroy via `TerminalManager.destroySurfaces(terminalIDs:)` before
    /// the UI re-creates the worktree (`GIT-3.9`).
    ///
    /// When a worktree went stale *while running* (`GIT-3.4` keeps its
    /// Ghostty surfaces alive across the stale transition), those
    /// surfaces are still registered in `TerminalManager`. The resurrect
    /// path then creates a *new* `TerminalID` and a *new* surface, which
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
    public mutating func prepareForResurrection() -> [TerminalID] {
        let oldLeaves = splitTree.allLeaves
        state = .closed
        splitTree = SplitTree(root: nil)
        focusedTerminalID = nil
        paneAttention.removeAll()
        return oldLeaves
    }

    /// Returns the leaf `TerminalID`s whose surfaces the caller MUST
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
    /// Clearing `splitTree` / `focusedTerminalID` / `paneAttention`
    /// here is largely symbolic since the caller is about to drop the
    /// whole entry, but it ensures a caller that ignores the return
    /// value leaves a visibly-empty entry rather than a sidebar row
    /// that still looks populated.
    @discardableResult
    public mutating func prepareForDismissal() -> [TerminalID] {
        let leaves = splitTree.allLeaves
        splitTree = SplitTree(root: nil)
        focusedTerminalID = nil
        paneAttention.removeAll()
        return leaves
    }

    /// Transitions the entry from `.running` to `.closed` as part of the
    /// Stop menu action, dropping `paneAttention` for every pane (all
    /// panes are being destroyed; their pane-scoped badges must go per
    /// `STATE-2.11`). Leaves `splitTree` and `focusedTerminalID` alone
    /// so re-open recreates the exact same layout at the same leaf IDs
    /// (`TERM-1.2`), and leaves the worktree-level `attention` slot
    /// alone since a CLI-notify ping is a worktree-level concern
    /// independent of which panes are alive.
    public mutating func prepareForStop() {
        state = .closed
        paneAttention.removeAll()
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
    /// would be ambiguous. Fall back to `parent/last` to disambiguate.
    ///
    /// `siblingPaths` must include this worktree's own path; the count
    /// tells us whether there's a collision.
    public func displayName(amongSiblingPaths siblingPaths: [String]) -> String {
        let lastComponent = (path as NSString).lastPathComponent
        let fallback = lastComponent.isEmpty ? branch : lastComponent

        // Is there any OTHER worktree in the repo with the same last
        // component? If so, disambiguate.
        let collides = siblingPaths.contains { siblingPath in
            siblingPath != path &&
            (siblingPath as NSString).lastPathComponent == lastComponent
        }
        guard collides else { return fallback }

        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !parent.isEmpty else { return fallback }
        return "\(parent)/\(lastComponent)"
    }
}

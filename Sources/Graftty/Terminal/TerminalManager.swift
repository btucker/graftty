import AppKit
import GhosttyKit
import GrafttyKit
@preconcurrency import UserNotifications

/// Spatial direction for pane navigation (goto_split left/right/up/down).
/// Promoted to top-level so both `TerminalManager` (callback signature) and
/// `GrafttyApp` (dispatch and menu) can reference it without qualification.
enum NavigationDirection {
    case left, right, up, down

    /// Bridge to `SplitTree.SpatialDirection`. Kept as a simple 1:1 map so
    /// the UI-layer enum stays app-local while the navigation policy lives
    /// in GrafttyKit where it can be unit-tested (TERM-7.3).
    var asSpatial: SplitTree.SpatialDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}


/// Compound key identifying "this terminal's most recent position inside
/// this worktree." Used by `TerminalManager` to remember where a pane was
/// so it can be restored if the pane returns.
struct PaneHistoryKey: Hashable {
    let terminalID: TerminalID
    let worktreePath: String
}

/// Central lifecycle manager for libghostty surfaces.
///
/// Owns a single `ghostty_app_t` (via `GhosttyApp`) and a map from `TerminalID`
/// to `SurfaceHandle`. Bridges the model layer to libghostty.
///
/// # Threading
/// `@MainActor`-isolated. The underlying `GhosttyApp` may fire wakeup/action
/// callbacks from background threads; wakeups arrive as `Notification.Name.ghosttyWakeup`
/// which we observe on the main queue and translate into `tick()` calls.
@MainActor
final class TerminalManager: ObservableObject {
    private var ghosttyApp: GhosttyApp?
    private var ghosttyConfig: GhosttyConfig?
    private var surfaces: [TerminalID: SurfaceHandle] = [:]

    var ptyDeviceAvailability: () -> PtyDeviceAvailability = {
        PtyDeviceAvailability.live()
    }

    /// Terminal IDs for which `onShellReady` has already fired. Used to
    /// gate the callback to exactly one invocation per pane.
    private var shellReadyFired: Set<TerminalID> = []

    private enum ZmxSessionSnapshot {
        case live(Set<String>)
        case unavailable
    }

    /// Terminal IDs that are the "first pane" of a worktree — the pane
    /// whose creation caused `.closed → .running`. Populated by
    /// `markFirstPane(_:)` from the sidebar/open-worktree path.
    private var firstPaneMarkers: Set<TerminalID> = []

    /// Terminal IDs that were recreated by restore-on-launch rather than
    /// user-initiated open. Populated by `markRehydrated(_:)` from
    /// `GrafttyApp.restoreRunningWorktrees`.
    private var rehydratedSurfaces: Set<TerminalID> = []

    private var wakeupObserver: NSObjectProtocol?

    /// Set by `GrafttyApp` at startup. When non-nil and `isAvailable`,
    /// every new surface spawns `zmx attach <session> $SHELL` so the
    /// session survives Graftty quits. When nil or unavailable, surfaces
    /// fall back to libghostty's default $SHELL spawn.
    var zmxLauncher: ZmxLauncher?

    /// `(terminalID → inner-shell PID)` cache. Resolving the shell PID
    /// from a zmx session log involves a disk read; the menu's "Move to
    /// current worktree" action calls `shellCwd(for:)` per right-click,
    /// so a one-shot lookup that re-uses the cached PID across clicks
    /// keeps that interaction snappy. Entries are dropped lazily on miss
    /// (shell exited / respawned) and via `forgetSurfaceRuntimeState`.
    private var cachedShellPIDs: [TerminalID: Int32] = [:]

    /// Theme colors pulled from the ghostty config (background, foreground).
    /// Emitted post-`initialize()` once the config is read; defaults to
    /// `.fallback` before that so views have something to render with.
    @Published var theme: GhosttyTheme = .fallback

    /// Per-pane titles set by the running program via the OSC-0/OSC-2 escape
    /// sequences (e.g. `\033]0;TITLE\007`). Populated in response to
    /// `GHOSTTY_ACTION_SET_TITLE` after filtering obvious env-assignment
    /// leaks via `PaneTitle.isLikelyEnvAssignment`; cleaned up on
    /// `destroySurface`. Not persisted — these are ephemeral runtime
    /// state that die with their shell. The sidebar reads this through
    /// `displayTitle(for:)`, which also applies the PWD-basename fallback.
    @Published var titles: [TerminalID: String] = [:]

    /// Per-pane last-known working directory, populated from OSC 7
    /// (`GHOSTTY_ACTION_PWD`). Used as the second tier of the sidebar
    /// label fallback chain after `titles`. Cleaned up on
    /// `destroySurface` alongside `titles`.
    @Published var pwds: [TerminalID: String] = [:]

    /// Ghostty-config-derived keybind map, built in `initialize()` from the
    /// live `ghostty_config_t` via `GhosttyTriggerAdapter.resolver`.
    /// `GrafttyApp.commands` reads this to set menu `.keyboardShortcut(...)`
    /// modifiers dynamically.
    @Published private(set) var keybindBridge: GhosttyKeybindBridge =
        GhosttyKeybindBridge(resolver: { _ in nil })

    /// True when the user's Ghostty config has `split-preserve-zoom =
    /// navigation` (explicit opt-in from Ghostty 1.3). When true, a
    /// goto_split from a zoomed pane transfers zoom to the newly focused
    /// leaf instead of unzooming. Not `@Published` — only `navigatePane`
    /// reads it (synchronously), so a SwiftUI invalidation cascade here
    /// would just cause no-op re-renders.
    private(set) var splitPreserveZoomOnNavigation: Bool = false

    /// Remembered split-tree positions for terminals that have moved *out*
    /// of a worktree via PWD change. If the same pane later hops back
    /// (e.g., user `cd`s in/out/in), we use the breadcrumb to reinsert it
    /// next to its former neighbor instead of an arbitrary leaf.
    ///
    /// Outer key is `(terminalID, worktreePath)` compressed into a struct —
    /// a single terminal can accumulate history across several worktrees
    /// if the user keeps bouncing it around.
    private var rememberedPositions: [PaneHistoryKey: SplitTree.LeafPosition] = [:]

    /// Called when a terminal surface requests a split (from the right-click
    /// context menu, from libghostty action callbacks, or from future keyboard
    /// bindings). The host (GrafttyApp) wires this up to mutate AppState and
    /// spawn a new surface; without it, split requests no-op.
    var onSplitRequest: ((TerminalID, PaneSplit) -> Void)?

    /// Called when a terminal surface's right-click menu requests a
    /// move-to-worktree (PWD-1.1 / PWD-1.3). The host (GrafttyApp) wires
    /// this up to mutate AppState through the same `reassignPaneByPWD`
    /// path that the sidebar's pane-row menu uses. Without this wired,
    /// the menu items are no-ops.
    var onMovePane: ((TerminalID, String) -> Void)?

    /// Resolves the snapshot of model state needed to build the
    /// Move-to-worktree menu items for `terminalID`. Returns nil when
    /// the pane isn't currently parked in any worktree (e.g. mid-move
    /// race window). The host (GrafttyApp) wires this against
    /// `AppState`; the surface menu (`SurfaceContextMenu`) calls it at
    /// menu-open time so the sampled state is fresh.
    var currentPaneMoveContext: ((TerminalID) -> PaneMoveMenuContext?)?

    /// Called when libghostty asks the host to close a surface (shell exited,
    /// or user-initiated request-close that's been confirmed). The host
    /// removes the pane from the split tree and calls `destroySurface`.
    /// Without this wired, the surface lingers and the pane appears hung.
    var onCloseRequest: ((TerminalID) -> Void)?

    /// Called on shell-integration "command finished" events (requires
    /// ghostty shell integration to be sourced, which our env injection
    /// takes care of when Ghostty.app's resources are available). The
    /// host maps this to the worktree's attention badge — errors become
    /// red badges, long successful commands become subtle pings so the
    /// user knows the pane is idle again.
    var onCommandFinished: ((TerminalID, _ exitCode: Int16, _ duration: UInt64) -> Void)?

    /// Fired exactly once per `TerminalID` — on the first
    /// `GHOSTTY_ACTION_PWD` event received for that pane. This is our
    /// "shell is ready to accept typed input" signal: Ghostty's shell
    /// integration emits OSC 7 from `precmd`, which runs before every
    /// prompt including the first one. If shell integration is absent
    /// (or the user is using an unsupported shell), this callback
    /// never fires — consumers should treat that as a silent no-op
    /// rather than fall back to time-based heuristics.
    var onShellReady: ((TerminalID) -> Void)?

    /// Called on OSC 9;4 progress reports from programs like `git clone`
    /// or `apt` that advertise progress. The host updates the attention
    /// badge so the user can keep tabs on long-running jobs without
    /// staying on the pane.
    var onProgressReport: ((TerminalID, ProgressReport) -> Void)?

    /// Called when libghostty dispatches `goto_split` with a spatial
    /// direction (left/right/up/down). Host navigates focus to the
    /// nearest neighbor in that direction.
    var onGotoSplit: ((TerminalID, NavigationDirection) -> Void)?

    /// Called when libghostty dispatches `goto_split:previous` or
    /// `goto_split:next`. Host cycles focus in split-tree leaf order.
    /// `forward` is `true` for next, `false` for previous.
    var onGotoSplitOrder: ((TerminalID, _ forward: Bool) -> Void)?

    /// Called when libghostty dispatches `toggle_split_zoom`. Host flips the
    /// `zoomed` state on the worktree containing `terminalID`.
    var onToggleZoom: ((TerminalID) -> Void)?

    /// Called on `resize_split`. Host walks up the split tree for the focused
    /// worktree and applies `SplitTree.resizing(...)`.
    var onResizeSplit: ((TerminalID, ResizeDirection, UInt16) -> Void)?

    /// Called on `equalize_splits`. Host runs `SplitTree.equalizing()` on the
    /// worktree containing `terminalID`.
    var onEqualizeSplits: ((TerminalID) -> Void)?

    /// Called on `reload_config`. Host rebuilds the keybind bridge so menu
    /// shortcuts update to match the new config.
    var onReloadConfig: (() -> Void)?

    /// Called on `open_config`. Host resolves the on-disk config file and
    /// hands it to the user's default editor via `NSWorkspace`. `TERM-9.2`.
    var onOpenConfig: (() -> Void)?

    /// Resolves the user's configured editor (Settings → shell $EDITOR → vi).
    /// Optional so tests can construct without a real probe; production always
    /// sets it via `GrafttyApp`.
    var editorPreference: EditorPreference?

    /// Fired when cmd-click resolves to a CLI editor; owner spawns a new
    /// pane split-right of the source with `initialInput` as the command.
    var onOpenInEditorPane: ((TerminalID, String) -> Void)?

    /// Swift-native mirror of `ghostty_action_progress_report_s` so
    /// callers outside the Terminal module don't need to import
    /// GhosttyKit just to pattern-match on progress state.
    enum ProgressReport {
        case indeterminate
        case paused
        case error
        /// 0–100 when the terminal program reported an exact percentage.
        case percent(Int8)
    }

    /// Path to the Graftty control socket, exposed to spawned shells via `GRAFTTY_SOCK`.
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if let wakeupObserver {
            NotificationCenter.default.removeObserver(wakeupObserver)
        }
    }

    /// One-time setup: calls `ghostty_init`, builds the shared `ghostty_app_t`,
    /// and subscribes to wakeup notifications. Safe to call only once per instance.
    func initialize() {
        precondition(ghosttyApp == nil, "TerminalManager.initialize() called more than once")

        // Point libghostty at a resources directory BEFORE `ghostty_init`.
        // It reads `GHOSTTY_RESOURCES_DIR` to locate shell-integration
        // scripts (zsh hooks that emit OSC 7 for PWD changes, OSC 133 for
        // prompt marks, etc.). libghostty-spm doesn't ship these, so
        // without this Graftty shells are "dumb" — no auto-PWD reporting,
        // no prompt integration. Borrow them from Ghostty.app if the user
        // has it installed; silently skip otherwise (shells still work,
        // just without integration features).
        Self.pointAtGhosttyResourcesIfAvailable()

        // ghostty_init must run before ghostty_config_new / ghostty_app_new.
        // It takes argc/argv; we pass 0/null since we don't forward CLI args.
        let rc = ghostty_init(0, nil)
        if rc != 0 {
            fatalError("ghostty_init failed with code \(rc)")
        }

        let config = GhosttyConfig()
        self.ghosttyConfig = config

        let app = GhosttyApp(config: config) { [weak self] target, action in
            // action_cb may fire from any thread; hop to main before touching state.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleAction(target: target, action: action)
                }
            } else {
                DispatchQueue.main.async {
                    self?.handleAction(target: target, action: action)
                }
            }
            return true
        }
        self.ghosttyApp = app
        self.theme = app.theme

        wakeupObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyWakeup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ghosttyApp?.tick()
            }
        }

        if let config = ghosttyConfig?.config {
            self.keybindBridge = GhosttyKeybindBridge(
                resolver: GhosttyTriggerAdapter.resolver(config: config)
            )
        }
        readSplitPreserveZoomConfig()
    }

    /// Best-effort lookup of the inner shell's current working directory
    /// for `id`. Returns nil when the zmx launcher is unavailable, the
    /// session log doesn't yield a PID, or the kernel rejects the
    /// `proc_pidinfo` call (process gone). Drives the right-click "Move
    /// to current worktree" menu item — a stale or missing answer just
    /// disables that item, never breaks anything.
    func shellCwd(for id: TerminalID) -> String? {
        if let cached = cachedShellPIDs[id],
           let cwd = PIDCwdReader.cwd(ofPID: cached) {
            return cwd
        }
        cachedShellPIDs.removeValue(forKey: id)
        guard let launcher = zmxLauncher, launcher.isAvailable else { return nil }
        let sessionName = launcher.sessionName(for: id.id)
        guard let pid = ZmxPIDLookup.shellPID(
            logFile: launcher.logFile(forSession: sessionName),
            sessionName: sessionName
        ) else {
            return nil
        }
        cachedShellPIDs[id] = pid
        return PIDCwdReader.cwd(ofPID: pid)
    }

    /// Rebuild the keybind bridge from the current config. Call after
    /// `ghostty_config_*` reload operations so menu shortcuts update to
    /// reflect any changes the user made to their Ghostty config.
    func rebuildKeybindBridge() {
        guard let config = ghosttyConfig?.config else { return }
        self.keybindBridge = GhosttyKeybindBridge(
            resolver: GhosttyTriggerAdapter.resolver(config: config)
        )
        readSplitPreserveZoomConfig()
    }

    /// Re-read the user's Ghostty config from disk and push it into the
    /// live app. Unlike `rebuildKeybindBridge` which only re-queries
    /// Graftty's bridge against the existing config pointer, this
    /// actually reloads the files (`GhosttyConfig.init` walks XDG +
    /// `com.mitchellh.ghostty` + recursive includes + finalize) and
    /// hands the result to `ghostty_app_update_config`. TERM-9.1.
    ///
    /// Ownership: the new `GhosttyConfig` transfers to the app on
    /// `ghostty_app_update_config`, mirroring `ghostty_app_new`. We
    /// mark `ownershipTransferred` so the wrapper's deinit doesn't
    /// double-free. The previous `ghosttyConfig` is replaced; its
    /// libghostty storage is freed internally by `update_config`.
    func reloadGhosttyConfig() {
        guard let app = ghosttyApp?.app else { return }
        let newConfig = GhosttyConfig()
        ghostty_app_update_config(app, newConfig.config)
        newConfig.ownershipTransferred = true
        self.ghosttyConfig = newConfig
        rebuildKeybindBridge()
    }

    /// Read `split-preserve-zoom` from the live config and update
    /// `splitPreserveZoomOnNavigation`. Called after `initialize()` and
    /// after every `rebuildKeybindBridge()` so the flag tracks reloads.
    ///
    /// `ghostty_config_get` writes a `ghostty_string_s` (ptr + len) into
    /// the void* output when the key maps to a string-typed config value.
    /// Returns false when the key is unknown or not set, leaving the flag
    /// at its default (false / unzoom-on-navigate).
    private func readSplitPreserveZoomConfig() {
        guard let config = ghosttyConfig?.config else { return }
        var present = false
        "split-preserve-zoom".withCString { cstr in
            var result = ghostty_string_s()
            let ok = ghostty_config_get(config, &result, cstr, UInt(strlen(cstr)))
            if ok, let ptr = result.ptr {
                let value = String(cString: ptr)
                present = value.contains("navigation")
            }
        }
        self.splitPreserveZoomOnNavigation = present
    }

    /// Create surfaces for every leaf in the given split tree that does not yet
    /// have a surface. Returns the subset that was newly created.
    @discardableResult
    func createSurfaces(
        for splitTree: SplitTree,
        worktreePath: String
    ) -> [TerminalID: SurfaceHandle] {
        guard let app = ghosttyApp?.app else { return [:] }

        var zmxSessionSnapshot: ZmxSessionSnapshot?
        func liveSessionsIfNeeded(for terminalID: TerminalID) -> ZmxSessionSnapshot? {
            guard rehydratedSurfaces.contains(terminalID),
                  let launcher = zmxLauncher else { return nil }
            if zmxSessionSnapshot == nil {
                zmxSessionSnapshot = (try? launcher.listSessions())
                    .map(ZmxSessionSnapshot.live) ?? .unavailable
            }
            return zmxSessionSnapshot
        }

        var created: [TerminalID: SurfaceHandle] = [:]
        for terminalID in splitTree.allLeaves where surfaces[terminalID] == nil {
            guard canAllocatePTY(for: terminalID) else { continue }
            clearRehydratedIfDaemonGone(
                terminalID,
                sessionSnapshot: liveSessionsIfNeeded(for: terminalID)
            )
            let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
            // TERM-5.5: SurfaceHandle.init is failable now — ghostty_surface_new
            // can return null under libghostty resource exhaustion. Skip the
            // leaf rather than crash the app; the pane renders the Color.black
            // + ProgressView fallback until it's re-created.
            guard let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath,
                zmxInitialInput: zmxInitialInput,
                zmxDir: zmxDir,
                terminalManager: self
            ) else { continue }
            surfaces[terminalID] = handle
            created[terminalID] = handle
        }
        return created
    }

    /// Create a single surface, or return the existing one for this `TerminalID`.
    func createSurface(
        terminalID: TerminalID,
        worktreePath: String,
        extraInitialInput: String? = nil
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        if let existing = surfaces[terminalID] {
            return existing
        }

        guard canAllocatePTY(for: terminalID) else { return nil }
        clearRehydratedIfDaemonGone(terminalID, sessionSnapshot: nil)

        let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
        // TERM-5.5: failable init returns nil on libghostty rejection;
        // propagate that to the caller instead of crashing.
        guard let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxInitialInput: zmxInitialInput,
            extraInitialInput: extraInitialInput,
            zmxDir: zmxDir,
            terminalManager: self
        ) else { return nil }
        surfaces[terminalID] = handle
        return handle
    }

    private func canAllocatePTY(for terminalID: TerminalID) -> Bool {
        guard ptyDeviceAvailability() == .available else {
            NSLog("[Graftty] PTY allocation unavailable; skipping surface creation for %@", terminalID.id.uuidString)
            return false
        }
        return true
    }

    /// Cold-start session-loss check (ZMX-7.1): if a rehydrated pane's
    /// zmx daemon is gone, the imminent `zmx attach` will create a fresh
    /// daemon — treat the pane as fresh so the default command runs.
    /// `sessionSnapshot` lets callers batch one `zmx list` across many
    /// leaves; pass `nil` to fall back to a per-call check.
    private func clearRehydratedIfDaemonGone(
        _ terminalID: TerminalID,
        sessionSnapshot: ZmxSessionSnapshot?
    ) {
        guard rehydratedSurfaces.contains(terminalID),
              let launcher = zmxLauncher else { return }
        let name = launcher.sessionName(for: terminalID.id)
        let missing: Bool
        switch sessionSnapshot {
        case .live(let sessions):
            missing = !sessions.contains(name)
        case .unavailable:
            missing = false
        case nil:
            missing = launcher.isSessionMissing(name)
        }
        if missing { clearRehydrated(terminalID) }
    }

    /// Drop per-instantiation runtime state tied to the current libghostty
    /// surface and shell (title, shell-ready flag, PID cache). The
    /// lifecycle labels (firstPaneMarkers, rehydratedSurfaces) outlive
    /// this and are cleaned up separately in `forgetTrackingState`.
    private func forgetSurfaceRuntimeState(for terminalID: TerminalID) {
        surfaces.removeValue(forKey: terminalID)
        titles.removeValue(forKey: terminalID)
        pwds.removeValue(forKey: terminalID)
        shellReadyFired.remove(terminalID)
        cachedShellPIDs.removeValue(forKey: terminalID)
    }

    /// The rendered sidebar label for a pane. Chains in priority order:
    /// program-set title (already filtered at intake), PWD basename,
    /// then empty — callers render the "shell" fallback on empty per
    /// LAYOUT-2.9.
    func displayTitle(for terminalID: TerminalID) -> String {
        PaneTitle.display(
            storedTitle: titles[terminalID],
            pwd: pwds[terminalID]
        )
    }

    /// Look up the `NSView` hosting a given terminal's surface.
    func view(for terminalID: TerminalID) -> NSView? {
        surfaces[terminalID]?.view
    }

    /// Look up the `SurfaceHandle` for a given terminal.
    func handle(for terminalID: TerminalID) -> SurfaceHandle? {
        surfaces[terminalID]
    }

    /// Tell libghostty whether a surface is currently visible. On visible,
    /// force a repaint so a re-shown pane presents a clean full frame.
    func setVisible(_ visible: Bool, for terminalID: TerminalID) {
        guard let handle = surfaces[terminalID] else { return }
        handle.setVisible(visible)
        if visible {
            handle.refresh()
        }
    }

    /// Force a full repaint for a visible or soon-to-be-visible surface.
    func refreshSurface(for terminalID: TerminalID) {
        surfaces[terminalID]?.refresh()
    }

    /// Returns the terminal's current text selection as a `String`, or
    /// `nil` when the surface is unknown or has no selection. Caps the
    /// UTF-8 copy at 4 KB since the only caller sanitizes+truncates to
    /// 100 characters — a multi-megabyte `cat` selection would otherwise
    /// force a full UTF-8 validation and `String` copy.
    func readSelection(for terminalID: TerminalID) -> String? {
        guard let handle = handle(for: terminalID) else { return nil }
        let surface = handle.surface
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        let len = min(Int(text.text_len), 4096)
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
            count: len
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Focus exactly one surface (by ID); unfocus the rest.
    func setFocus(_ terminalID: TerminalID) {
        for (id, handle) in surfaces {
            if id == terminalID {
                handle.setVisible(true)
                handle.refresh()
            }
            handle.setFocus(id == terminalID)
        }
    }

    /// Whether any of the given terminals has a process that requires confirmation before quit.
    func needsConfirmQuit(terminalIDs: [TerminalID]) -> Bool {
        terminalIDs.contains { surfaces[$0]?.needsConfirmQuit == true }
    }

    /// Request close on each named surface and drop our reference. The surface itself
    /// is freed when the last strong reference to the `SurfaceHandle` drops.
    func destroySurfaces(terminalIDs: [TerminalID]) {
        for id in terminalIDs {
            destroySurface(terminalID: id)
        }
    }

    func destroySurface(terminalID: TerminalID) {
        surfaces[terminalID]?.requestClose()
        forgetSurfaceRuntimeState(for: terminalID)
        killZmxSession(for: terminalID)
        forgetTrackingState(for: terminalID)
    }

    /// Mark a terminal as the first pane of its worktree — the pane whose
    /// creation caused the worktree to transition from `.closed` to
    /// `.running`. Called by the sidebar "Open" action (and any other
    /// caller that triggers a `.closed → .running` transition).
    func markFirstPane(_ terminalID: TerminalID) {
        firstPaneMarkers.insert(terminalID)
    }

    /// Mark a terminal as rehydrated from on-disk state at launch, rather
    /// than freshly opened by the user. Rehydrated panes never auto-run
    /// a default command — the command is presumed already running under
    /// zmx from the previous session. Called by
    /// `GrafttyApp.restoreRunningWorktrees` before creating surfaces.
    func markRehydrated(_ terminalID: TerminalID) {
        rehydratedSurfaces.insert(terminalID)
    }

    /// Drop the rehydration label so `defaultCommandDecision` treats a
    /// pane as fresh. Called by `clearRehydratedIfDaemonGone`.
    func clearRehydrated(_ terminalID: TerminalID) {
        rehydratedSurfaces.remove(terminalID)
    }

    /// Whether a terminal was marked as the first pane of its worktree.
    func isFirstPane(_ terminalID: TerminalID) -> Bool {
        firstPaneMarkers.contains(terminalID)
    }

    /// Whether a terminal was marked as rehydrated rather than user-opened.
    func wasRehydrated(_ terminalID: TerminalID) -> Bool {
        rehydratedSurfaces.contains(terminalID)
    }

    /// Clear per-terminal tracking state on destroy. Keeps the three
    /// tracking sets in sync with live surfaces so destroyed IDs don't
    /// leak memory or cause stale answers from the marker queries.
    private func forgetTrackingState(for terminalID: TerminalID) {
        shellReadyFired.remove(terminalID)
        firstPaneMarkers.remove(terminalID)
        rehydratedSurfaces.remove(terminalID)
    }

    /// Resolve the per-surface zmx spawn parameters for a terminal pane.
    /// Returns (nil, nil) when no launcher is configured or the binary is
    /// missing — in which case `SurfaceHandle` falls back to libghostty's
    /// default `$SHELL` spawn (existing pre-zmx behavior).
    ///
    /// When available, we return the `initial_input` bytes for libghostty
    /// to write into the PTY right after it spawns the user's default
    /// shell. Those bytes are an `exec zmx attach …` line that replaces
    /// the shell with the zmx client — see `ZmxLauncher.attachInitialInput`
    /// for why we use initial_input rather than `config.command`.
    private func resolveZmxSpawn(for terminalID: TerminalID) -> (initialInput: String?, dir: String?) {
        guard let launcher = zmxLauncher, launcher.isAvailable else {
            return (nil, nil)
        }
        let session = launcher.sessionName(for: terminalID.id)
        // Resolve the user's shell once from the app-launch environment.
        // This is the same SHELL libghostty will spawn when config.command
        // is nil; we hand it back to zmx as the inner process so the
        // attached session runs the user's real shell.
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        // Pass GHOSTTY_RESOURCES_DIR through so the launcher can re-inject
        // ZDOTDIR for zsh users. Without this, Ghostty's shell integration
        // never loads in the inner shell zmx spawns, and chpwd-driven OSC 7
        // (the signal behind PWD-follow) goes silent.
        let ghosttyResources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
        return (
            launcher.attachInitialInput(
                sessionName: session,
                userShell: userShell,
                ghosttyResourcesDir: ghosttyResources
            ),
            launcher.zmxDir.path
        )
    }

    /// Fire-off the `zmx kill` for a terminal's session. Dispatched off
    /// the main thread because subprocess wait can take tens of ms; we
    /// don't want to block UI. Result is intentionally ignored — kill of
    /// an already-gone session is the success outcome.
    private func killZmxSession(for terminalID: TerminalID) {
        guard let launcher = zmxLauncher, launcher.isAvailable else { return }
        let name = launcher.sessionName(for: terminalID.id)
        DispatchQueue.global(qos: .utility).async {
            launcher.kill(sessionName: name)
        }
    }

    /// If `GHOSTTY_RESOURCES_DIR` isn't already set and Ghostty.app is
    /// installed, borrow its resources directory. Respects an existing
    /// value (user overrides from the shell environment win) and respects
    /// the user's choice to install Ghostty elsewhere by walking a couple
    /// of standard locations before giving up.
    private static func pointAtGhosttyResourcesIfAvailable() {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return
        }
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            (NSHomeDirectory() as NSString).appendingPathComponent(
                "Applications/Ghostty.app/Contents/Resources/ghostty"
            ),
        ]
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }

    /// Snapshot the given leaf's position inside a worktree's tree so we
    /// can restore it later. Called just before removing the leaf.
    func rememberPosition(
        terminalID: TerminalID,
        worktreePath: String,
        in tree: SplitTree
    ) {
        guard let position = tree.position(of: terminalID) else { return }
        rememberedPositions[PaneHistoryKey(terminalID: terminalID, worktreePath: worktreePath)] = position
    }

    /// Retrieve a previously-remembered position, if any. Does not consume —
    /// if the pane fails to rejoin for any reason, the breadcrumb stays
    /// available for the next attempt.
    func rememberedPosition(
        terminalID: TerminalID,
        worktreePath: String
    ) -> SplitTree.LeafPosition? {
        rememberedPositions[PaneHistoryKey(terminalID: terminalID, worktreePath: worktreePath)]
    }

    /// Drop the breadcrumb (optional cleanup on successful rejoin — keeps
    /// the map from growing unboundedly if a pane bounces a lot).
    func forgetPosition(terminalID: TerminalID, worktreePath: String) {
        rememberedPositions.removeValue(forKey: PaneHistoryKey(terminalID: terminalID, worktreePath: worktreePath))
    }

    /// Resolve a libghostty `ghostty_target_s` back to an Graftty `TerminalID`
    /// via the surface's userdata box. Returns nil for app-scoped targets or
    /// when the surface pointer has no box attached (shouldn't happen for
    /// surfaces we created).
    private func terminalID(from target: ghostty_target_s) -> TerminalID? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return nil }
        let box = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
        return box.terminalID
    }

    /// Handles libghostty actions. We dispatch only the tags Graftty
    /// currently cares about; unknown tags are a silent no-op so libghostty
    /// upgrades don't force immediate handling of new actions.
    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let id = terminalID(from: target) else { return }
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            // Drop the env-assignment leak from ghostty's outer-shell
            // preexec hook AND any payload that would bloat the titles
            // dict past `maxStoredLength`. A legitimate title pushed
            // by the inner shell later still wins because we write the
            // filtered value back. See `PaneTitle.sanitize`.
            if let sanitized = PaneTitle.sanitize(title), titles[id] != sanitized {
                titles[id] = sanitized
            }

        case GHOSTTY_ACTION_PWD:
            guard let id = terminalID(from: target) else { return }
            guard let pwdPtr = action.action.pwd.pwd else { return }
            let pwd = String(cString: pwdPtr)
            // Feeds `displayTitle(for:)`'s PWD-basename fallback.
            pwds[id] = pwd
            if shellReadyFired.insert(id).inserted {
                onShellReady?(id)
            }

        case GHOSTTY_ACTION_RING_BELL:
            // Default system alert sound. Visual bell (a brief flash) is a
            // nice follow-up but not essential for parity with Ghostty's
            // default behavior.
            NSSound.beep()

        case GHOSTTY_ACTION_OPEN_URL:
            let url = action.action.open_url
            guard let urlPtr = url.url else { return }
            let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(url.len))
            guard let urlString = String(
                bytes: bytes.map { UInt8(bitPattern: $0) },
                encoding: .utf8
            ) else { return }

            let sourceID = terminalID(from: target)
            let cwd = sourceID.flatMap { pwds[$0] }

            let classified = EditorOpenRouter.classify(urlString: urlString, paneCwd: cwd)

            // No editor preference (test-only) → only browser URLs are safe to
            // dispatch; file targets beep rather than reopen the "-50 dialog" bug.
            let editorAction: EditorOpenRouter.EditorAction
            if let editor = editorPreference?.resolve() {
                editorAction = EditorOpenRouter.resolve(target: classified, editor: editor)
            } else if case .browser(let u) = classified {
                editorAction = .openInBrowser(u)
            } else {
                editorAction = .noOp
            }

            switch editorAction {
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)

            case .openWithApp(let file, let app):
                let config = NSWorkspace.OpenConfiguration()
                config.promptsUserIfNeeded = false
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
                    { _, _ in }

            case .openInPane(let initialInput):
                guard let sourceID else { NSSound.beep(); break }
                onOpenInEditorPane?(sourceID, initialInput)

            case .noOp:
                NSSound.beep()
            }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else { return }
            view.applyCursor(Self.nsCursor(for: action.action.mouse_shape))

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = surfaceView(from: target) else { return }
            view.setCursorHidden(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // Informational: libghostty tells us the mouse is now over a
            // detected URL. We rely on MOUSE_SHAPE=POINTER for the visual
            // indication, so there's nothing extra to do here. Left
            // explicit (rather than falling into `default`) so future UI
            // (status bar link preview, etc.) has an obvious hook.
            break

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            let title = note.title.flatMap { String(cString: $0) } ?? "Terminal"
            let body = note.body.flatMap { String(cString: $0) } ?? ""
            Self.postDesktopNotification(title: title, body: body)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let id = terminalID(from: target) else { return }
            let finished = action.action.command_finished
            onCommandFinished?(id, finished.exit_code, finished.duration)

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let id = terminalID(from: target) else { return }
            let progress = action.action.progress_report
            let translated: ProgressReport
            switch progress.state {
            case GHOSTTY_PROGRESS_STATE_ERROR:         translated = .error
            case GHOSTTY_PROGRESS_STATE_INDETERMINATE: translated = .indeterminate
            case GHOSTTY_PROGRESS_STATE_PAUSE:         translated = .paused
            default:
                translated = progress.progress >= 0 ? .percent(progress.progress) : .indeterminate
            }
            onProgressReport?(id, translated)

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let id = terminalID(from: target) else { return }
            let split: PaneSplit
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: split = .right
            case GHOSTTY_SPLIT_DIRECTION_LEFT:  split = .left
            case GHOSTTY_SPLIT_DIRECTION_UP:    split = .up
            case GHOSTTY_SPLIT_DIRECTION_DOWN:  split = .down
            default: return
            }
            onSplitRequest?(id, split)

        case GHOSTTY_ACTION_CLOSE_TAB:
            // Ghostty reuses close_tab for close_surface in single-pane
            // contexts; Graftty treats pane close the same way.
            guard let id = terminalID(from: target) else { return }
            onCloseRequest?(id)

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let id = terminalID(from: target) else { return }
            let gotoDir = action.action.goto_split
            switch gotoDir {
            case GHOSTTY_GOTO_SPLIT_LEFT:   onGotoSplit?(id, .left)
            case GHOSTTY_GOTO_SPLIT_RIGHT:  onGotoSplit?(id, .right)
            case GHOSTTY_GOTO_SPLIT_UP:     onGotoSplit?(id, .up)
            case GHOSTTY_GOTO_SPLIT_DOWN:   onGotoSplit?(id, .down)
            case GHOSTTY_GOTO_SPLIT_NEXT:     onGotoSplitOrder?(id, true)
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: onGotoSplitOrder?(id, false)
            default: return
            }

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let id = terminalID(from: target) else { return }
            onToggleZoom?(id)

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let id = terminalID(from: target) else { return }
            let r = action.action.resize_split
            let direction: ResizeDirection
            switch r.direction {
            case GHOSTTY_RESIZE_SPLIT_UP:    direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN:  direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT:  direction = .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT: direction = .right
            default: return
            }
            onResizeSplit?(id, direction, r.amount)

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let id = terminalID(from: target) else { return }
            onEqualizeSplits?(id)

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            onReloadConfig?()

        case GHOSTTY_ACTION_OPEN_CONFIG:
            onOpenConfig?()

        // Silent no-ops for Ghostty concepts Graftty doesn't model. Listed
        // explicitly (rather than falling into default) so future maintainers
        // know we considered them.
        case GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_MOVE_TAB,
             GHOSTTY_ACTION_GOTO_TAB,
             GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
             GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
             GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
             GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
             GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
             GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
             GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            break

        default:
            break
        }
    }

    /// Map libghostty's mouse shape enum to the closest `NSCursor`. Shapes
    /// without a macOS counterpart fall back to the text I-beam — the
    /// default over terminal cells — which matches Ghostty upstream's
    /// behavior of "show something reasonable if nothing fits exactly."
    private static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:         return .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER:         return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT:            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:   return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:       return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:         return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB:            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:        return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:       return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:       return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_CELL:            return .iBeam
        default:                                  return .iBeam
        }
    }

    private func surfaceView(from target: ghostty_target_s) -> SurfaceNSView? {
        guard let id = terminalID(from: target) else { return nil }
        return surfaces[id]?.view as? SurfaceNSView
    }

    /// Post a libghostty-initiated desktop notification through
    /// `UNUserNotificationCenter`. Silently skips if the user has
    /// declined authorization — macOS will log but not crash, and the
    /// terminal behavior is "notification didn't show" rather than
    /// "Graftty broken."
    private static func postDesktopNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let post = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post() }
                }
            default:
                break
            }
        }
    }
}

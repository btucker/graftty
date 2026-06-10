import AppKit
import Combine
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
    let terminalID: PaneSlotID
    let worktreePath: String
}

/// Central lifecycle manager for libghostty surfaces.
///
/// Owns a single `ghostty_app_t` (via `GhosttyApp`) and a map from `PaneSlotID`
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
    private var surfaces: [PaneSlotID: SurfaceHandle] = [:]
    private var evictedGridSizes: [PaneSlotID: GridSize] = [:]
    private var paneSessionIDs: [PaneSlotID: PaneSessionID] = [:]
    private var paneSlotIDsBySessionName: [String: PaneSlotID] = [:]

    /// Caps the number of worktrees with live surfaces (MEM-1.1).
    /// Lazy so it can capture `self` in the eviction callback after `init`.
    lazy var surfaceBudget: WorktreeSurfaceBudget = WorktreeSurfaceBudget { [weak self] leafID in
        self?.evictSurface(terminalID: leafID)
    }

    var ptyDeviceAvailability: () -> PtyDeviceAvailability = {
        PtyDeviceAvailability.live()
    }

    /// Terminal IDs for which `onShellReady` has already fired. Used to
    /// gate the callback to exactly one invocation per pane.
    private var shellReadyFired: Set<PaneSlotID> = []

    private enum ZmxSessionSnapshot {
        case live(Set<String>)
        case unavailable
    }

    /// Cached grid size for a pane whose surface was evicted by the LRU
    /// budget. Replayed as `initialGridSize:` on the next `createSurface`
    /// for the same pane so the outer `zmx attach` PTY is spawned at the
    /// captured winsize. Cleared on consume or on destroy.
    struct GridSize: Equatable {
        var cols: UInt16
        var rows: UInt16
        var widthPx: UInt32
        var heightPx: UInt32

        init(_ s: ghostty_surface_size_s) {
            cols = s.columns
            rows = s.rows
            widthPx = s.width_px
            heightPx = s.height_px
        }

        var asGhosttySize: ghostty_surface_size_s {
            ghostty_surface_size_s(
                columns: cols,
                rows: rows,
                width_px: widthPx,
                height_px: heightPx,
                cell_width_px: 0,
                cell_height_px: 0
            )
        }
    }

    /// Terminal IDs that are the "first pane" of a worktree — the pane
    /// whose creation caused `.closed → .running`. Populated by
    /// `markFirstPane(_:)` from the sidebar/open-worktree path.
    private var firstPaneMarkers: Set<PaneSlotID> = []

    /// Terminal IDs that were recreated by restore-on-launch rather than
    /// user-initiated open. Populated by `markRehydrated(_:)` from
    /// `GrafttyApp.restoreRunningWorktrees`.
    private var rehydratedSurfaces: Set<PaneSlotID> = []

    private var wakeupObserver: NSObjectProtocol?

    /// Set by `GrafttyApp` at startup. When non-nil and `isAvailable`,
    /// every new surface spawns `zmx attach <session> $SHELL` so the
    /// session survives Graftty quits. When nil or unavailable, surfaces
    /// fall back to libghostty's default $SHELL spawn.
    var zmxLauncher: ZmxLauncher?

    /// TERM-11.x: per-session remote attach counts; injected by
    /// GrafttyApp.startup() like zmxLauncher. Consulted (via SurfaceHandle)
    /// to decide whether the IOS-12.1 silent gate withholds PTY resizes.
    var remoteAttachmentRegistry: RemoteAttachmentRegistry?

    /// Set by `GrafttyApp` after construction. When non-nil, pane add /
    /// remove flows propagate registration so the scanner can poll
    /// listening sockets for each pane's process subtree.
    var portScanner: PortScanner?

    /// `(terminalID → inner-shell PID)` cache. Resolving the shell PID
    /// from a zmx session log involves a disk read; the menu's "Move to
    /// current worktree" action calls `shellCwd(for:)` per right-click,
    /// so a one-shot lookup that re-uses the cached PID across clicks
    /// keeps that interaction snappy. Entries are dropped lazily on miss
    /// (shell exited / respawned) and via `forgetSurfaceRuntimeState`.
    private var cachedShellPIDs: [PaneSlotID: Int32] = [:]

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
    var titles: [PaneSlotID: String] = [:]

    /// Per-pane last-known working directory, populated from OSC 7
    /// (`GHOSTTY_ACTION_PWD`). Used as the second tier of the sidebar
    /// label fallback chain after `titles`. Cleaned up on
    /// `destroySurface` alongside `titles`.
    var pwds: [PaneSlotID: String] = [:]

    /// Sidebar-only invalidation source for pane title changes. Keep this
    /// separate from TerminalManager's own objectWillChange because
    /// MainWindow observes the manager for theme/keybind changes; publishing
    /// pane titles through the manager invalidates the entire split view.
    let paneTitleInvalidations = PaneTitleInvalidationSource()

    /// Cached sidebar-visible pane titles. Raw `titles`/`pwds` can change
    /// frequently from shell integration; only display-equivalent changes
    /// trigger the sidebar-only invalidation source above.
    private var renderedTitles: [PaneSlotID: String] = [:]

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
    var onSplitRequest: ((PaneSlotID, PaneSplit) -> Void)?

    /// Called when a terminal surface's right-click menu requests a
    /// move-to-worktree (PWD-1.1 / PWD-1.3). The host (GrafttyApp) wires
    /// this up to mutate AppState through the same `reassignPaneByPWD`
    /// path that the sidebar's pane-row menu uses. Without this wired,
    /// the menu items are no-ops.
    var onMovePane: ((PaneSlotID, String) -> Void)?

    /// Resolves the snapshot of model state needed to build the
    /// Move-to-worktree menu items for `terminalID`. Returns nil when
    /// the pane isn't currently parked in any worktree (e.g. mid-move
    /// race window). The host (GrafttyApp) wires this against
    /// `AppState`; the surface menu (`SurfaceContextMenu`) calls it at
    /// menu-open time so the sampled state is fresh.
    var currentPaneMoveContext: ((PaneSlotID) -> PaneMoveMenuContext?)?

    /// Called when libghostty asks the host to close a surface (shell exited,
    /// or user-initiated request-close that's been confirmed). The host
    /// removes the pane from the split tree and calls `destroySurface`.
    /// Without this wired, the surface lingers and the pane appears hung.
    var onCloseRequest: ((PaneSlotID) -> Void)?

    /// Called on shell-integration "command finished" events (requires
    /// ghostty shell integration to be sourced, which our env injection
    /// takes care of when Ghostty.app's resources are available). The
    /// host maps this to the worktree's attention badge — errors become
    /// red badges, long successful commands become subtle pings so the
    /// user knows the pane is idle again.
    var onCommandFinished: ((PaneSlotID, _ exitCode: Int16, _ duration: UInt64) -> Void)?

    /// Fired exactly once per `PaneSlotID` — on the first
    /// `GHOSTTY_ACTION_PWD` event received for that pane. This is our
    /// "shell is ready to accept typed input" signal: Ghostty's shell
    /// integration emits OSC 7 from `precmd`, which runs before every
    /// prompt including the first one. If shell integration is absent
    /// (or the user is using an unsupported shell), this callback
    /// never fires — consumers should treat that as a silent no-op
    /// rather than fall back to time-based heuristics.
    var onShellReady: ((PaneSlotID) -> Void)?

    /// Called on OSC 9;4 progress reports from programs like `git clone`
    /// or `apt` that advertise progress. The host updates the attention
    /// badge so the user can keep tabs on long-running jobs without
    /// staying on the pane.
    var onProgressReport: ((PaneSlotID, ProgressReport) -> Void)?

    /// Called when libghostty dispatches `goto_split` with a spatial
    /// direction (left/right/up/down). Host navigates focus to the
    /// nearest neighbor in that direction.
    var onGotoSplit: ((PaneSlotID, NavigationDirection) -> Void)?

    /// Called when libghostty dispatches `goto_split:previous` or
    /// `goto_split:next`. Host cycles focus in split-tree leaf order.
    /// `forward` is `true` for next, `false` for previous.
    var onGotoSplitOrder: ((PaneSlotID, _ forward: Bool) -> Void)?

    /// Called when libghostty dispatches `toggle_split_zoom`. Host flips the
    /// `zoomed` state on the worktree containing `terminalID`.
    var onToggleZoom: ((PaneSlotID) -> Void)?

    /// Called on `resize_split`. Host walks up the split tree for the focused
    /// worktree and applies `SplitTree.resizing(...)`.
    var onResizeSplit: ((PaneSlotID, ResizeDirection, UInt16) -> Void)?

    /// Called on `equalize_splits`. Host runs `SplitTree.equalizing()` on the
    /// worktree containing `terminalID`.
    var onEqualizeSplits: ((PaneSlotID) -> Void)?

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

    /// Passive keystroke tap for the idle-delivery pipeline. Set by
    /// `GrafttyApp.startup()` after the pipeline is constructed; nil
    /// before that, which is safe — `SurfaceNSView.keyDown` nil-checks it.
    var inputActivityObserver: PaneInputActivityObserver?

    /// Fires once per surface destruction so the idle-delivery pipeline
    /// can evict per-pane registry entries (PaneInputActivityRegistry
    /// stamps, WorktreeAgentStateRegistry states, and TeamPresenceStorage
    /// records keyed off the pane's session name). Wired by
    /// `GrafttyApp.startup()` after the pipeline is constructed.
    var paneClosed: ((PaneSlotID, String?) -> Void)?

    /// Fired when cmd-click resolves to a CLI editor; owner spawns a new
    /// pane split-right of the source with `initialInput` as the command.
    var onOpenInEditorPane: ((PaneSlotID, String) -> Void)?

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
        // Graftty vendors them in GrafttyKit's resource bundle
        // (CONFIG-2.5) and points the env at that copy unless the user
        // set an explicit override.
        Self.pointAtGhosttyResources()

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
    func shellCwd(for id: PaneSlotID) -> String? {
        if let cached = cachedShellPIDs[id],
           let cwd = PIDCwdReader.cwd(ofPID: cached) {
            return cwd
        }
        cachedShellPIDs.removeValue(forKey: id)
        guard let pid = lookupShellPID(for: id) else { return nil }
        return PIDCwdReader.cwd(ofPID: pid)
    }

    /// Best-effort shell PID for a pane via the zmx daemon log. Returns
    /// nil for panes whose log hasn't been written yet — call sites
    /// should re-attempt later if needed. Caches successful lookups in
    /// `cachedShellPIDs` to amortize the log read across calls.
    func lookupShellPID(for id: PaneSlotID) -> pid_t? {
        if let cached = cachedShellPIDs[id] { return cached }
        guard let launcher = zmxLauncher, launcher.isAvailable else { return nil }
        guard let sessionName = zmxSessionName(for: id) else { return nil }
        guard let pid = ZmxPIDLookup.shellPID(
            logFile: launcher.logFile(forSession: sessionName),
            sessionName: sessionName
        ) else { return nil }
        cachedShellPIDs[id] = pid
        return pid
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
        self.theme = GhosttyTheme(config: newConfig)
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
        paneSessions: [PaneSlotID: PaneSessionID],
        worktreePath: String
    ) -> [PaneSlotID: SurfaceHandle] {
        guard let app = ghosttyApp?.app else { return [:] }

        var zmxSessionSnapshot: ZmxSessionSnapshot?
        func liveSessionsIfNeeded(for terminalID: PaneSlotID) -> ZmxSessionSnapshot? {
            guard rehydratedSurfaces.contains(terminalID),
                  let launcher = zmxLauncher else { return nil }
            if zmxSessionSnapshot == nil {
                zmxSessionSnapshot = (try? launcher.listSessions())
                    .map(ZmxSessionSnapshot.live) ?? .unavailable
            }
            return zmxSessionSnapshot
        }

        var created: [PaneSlotID: SurfaceHandle] = [:]
        for terminalID in splitTree.allLeaves where surfaces[terminalID] == nil {
            guard let paneSessionID = paneSessions[terminalID] else { continue }
            guard canAllocatePTY(for: terminalID) else { continue }
            recordPaneSession(paneSessionID, for: terminalID)
            clearRehydratedIfDaemonGone(
                terminalID,
                paneSessionID: paneSessionID,
                sessionSnapshot: liveSessionsIfNeeded(for: terminalID)
            )
            let zmxSpawnConfiguration = resolveZmxSpawnConfiguration(
                for: terminalID,
                paneSessionID: paneSessionID,
                worktreePath: worktreePath
            )
            // TERM-5.5: SurfaceHandle.init is failable now — ghostty_surface_new
            // can return null under libghostty resource exhaustion. Skip the
            // leaf rather than crash the app; the pane renders the Color.black
            // + ProgressView fallback until it's re-created.
            guard let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath,
                zmxSpawnConfiguration: zmxSpawnConfiguration,
                terminalManager: self,
                inputActivityObserver: inputActivityObserver,
                remoteAttachmentRegistry: remoteAttachmentRegistry,
                initialGridSize: consumeCachedGridSize(for: terminalID)
            ) else {
                forgetPaneSession(for: terminalID)
                continue
            }
            didCreateSurface(for: terminalID)
            surfaces[terminalID] = handle
            created[terminalID] = handle
            registerForPortScan(terminalID)
        }
        return created
    }

    /// Create a single surface, or return the existing one for this `PaneSlotID`.
    func createSurface(
        terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        extraInitialInput: String? = nil
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        if let existing = surfaces[terminalID] {
            return existing
        }

        guard canAllocatePTY(for: terminalID) else { return nil }
        recordPaneSession(paneSessionID, for: terminalID)
        clearRehydratedIfDaemonGone(terminalID, paneSessionID: paneSessionID, sessionSnapshot: nil)

        let zmxSpawnConfiguration = resolveZmxSpawnConfiguration(
            for: terminalID,
            paneSessionID: paneSessionID,
            worktreePath: worktreePath
        )
        // TERM-5.5: failable init returns nil on libghostty rejection;
        // propagate that to the caller instead of crashing.
        guard let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxSpawnConfiguration: zmxSpawnConfiguration,
            extraInitialInput: extraInitialInput,
            terminalManager: self,
            inputActivityObserver: inputActivityObserver,
            remoteAttachmentRegistry: remoteAttachmentRegistry,
            initialGridSize: consumeCachedGridSize(for: terminalID)
        ) else {
            forgetPaneSession(for: terminalID)
            return nil
        }
        didCreateSurface(for: terminalID)
        surfaces[terminalID] = handle
        registerForPortScan(terminalID)
        return handle
    }

    /// PORTS-4.5: At surface-creation time the zmx daemon may not have
    /// written its `pty spawned ... pid=N` line yet, so `lookupShellPID`
    /// can transiently return nil. Register as pending in that case so
    /// the scanner re-attempts resolution on each tick — otherwise the
    /// pane silently never gets scanned and chips never appear.
    private func registerForPortScan(_ terminalID: PaneSlotID) {
        guard let scanner = portScanner else { return }
        if let pid = lookupShellPID(for: terminalID) {
            Task { await scanner.registerPane(terminalID, shellPID: pid) }
        } else {
            Task { await scanner.registerPanePending(terminalID) }
        }
    }

    private func canAllocatePTY(for terminalID: PaneSlotID) -> Bool {
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
        _ terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        sessionSnapshot: ZmxSessionSnapshot?
    ) {
        guard rehydratedSurfaces.contains(terminalID),
              let launcher = zmxLauncher else { return }
        let name = launcher.sessionName(for: paneSessionID)
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
    private func forgetSurfaceRuntimeState(for terminalID: PaneSlotID) {
        surfaces.removeValue(forKey: terminalID)
        titles.removeValue(forKey: terminalID)
        pwds.removeValue(forKey: terminalID)
        if renderedTitles.removeValue(forKey: terminalID) != nil {
            paneTitleInvalidations.schedule()
        }
        shellReadyFired.remove(terminalID)
        cachedShellPIDs.removeValue(forKey: terminalID)
        paneClosed?(terminalID, zmxSessionName(for: terminalID))
    }

    /// The rendered sidebar label for a pane. Chains in priority order:
    /// program-set title (already filtered at intake), PWD basename,
    /// then empty — callers render the "shell" fallback on empty per
    /// LAYOUT-2.9.
    func displayTitle(for terminalID: PaneSlotID) -> String {
        renderedTitles[terminalID] ?? ""
    }

    /// Record a sanitized program-set title and return whether the rendered
    /// sidebar title changed. Rejected titles preserve the previous title.
    @discardableResult
    func recordTitle(_ title: String, for terminalID: PaneSlotID) -> Bool {
        guard let sanitized = PaneTitle.sanitize(title) else { return false }
        titles[terminalID] = sanitized
        return updateRenderedTitle(for: terminalID)
    }

    /// Record the pane's latest PWD and return whether the rendered sidebar
    /// title changed. The raw PWD is retained even when the basename display
    /// is unchanged so relative editor-open handling stays accurate.
    @discardableResult
    func recordPWD(_ pwd: String, for terminalID: PaneSlotID) -> Bool {
        pwds[terminalID] = pwd
        return updateRenderedTitle(for: terminalID)
    }

    private func updateRenderedTitle(for terminalID: PaneSlotID) -> Bool {
        let old = renderedTitles[terminalID] ?? ""
        let new = PaneTitle.display(
            storedTitle: titles[terminalID],
            pwd: pwds[terminalID]
        )
        guard old != new else { return false }
        if new.isEmpty {
            renderedTitles.removeValue(forKey: terminalID)
        } else {
            renderedTitles[terminalID] = new
        }
        paneTitleInvalidations.schedule()
        return true
    }

    /// Look up the `NSView` hosting a given terminal's surface.
    func view(for terminalID: PaneSlotID) -> NSView? {
        surfaces[terminalID]?.view
    }

    /// Look up the `SurfaceHandle` for a given terminal.
    func handle(for terminalID: PaneSlotID) -> SurfaceHandle? {
        surfaces[terminalID]
    }

    func handle(forSessionName sessionName: String) -> SurfaceHandle? {
        guard let paneSlotID = paneSlotIDsBySessionName[sessionName] else { return nil }
        return surfaces[paneSlotID]
    }

    /// Reverse-lookup of the pane UUID whose current runtime mapping
    /// derives the given zmx session name. This intentionally consults
    /// the mapping rather than `surfaces`, so metadata tests and late
    /// hook gates can verify session replacement without a real Ghostty
    /// surface.
    func paneID(forSessionName sessionName: String) -> UUID? {
        paneSlotIDsBySessionName[sessionName]?.id
    }

    /// Test seam: read the captured grid size for a pane.
    func evictedGridSize(for terminalID: PaneSlotID) -> GridSize? {
        evictedGridSizes[terminalID]
    }

    /// Test seam: insert a surface handle for tests that exercise
    /// `evictSurface` without a live ghostty app. Production callers use
    /// `createSurface` / `createSurfaces` exclusively.
    func insertSurfaceForTesting(_ handle: SurfaceHandle, for terminalID: PaneSlotID) {
        surfaces[terminalID] = handle
    }

    /// Drop and return the cached grid size for a pane, if any. Peek-then-
    /// consume rather than consume-then-spawn so a failable `SurfaceHandle`
    /// init can roll back and leave the cache available for the next retry.
    private func consumeCachedGridSize(for terminalID: PaneSlotID) -> ghostty_surface_size_s? {
        evictedGridSizes[terminalID]?.asGhosttySize
    }

    private func didCreateSurface(for terminalID: PaneSlotID) {
        evictedGridSizes.removeValue(forKey: terminalID)
    }

    /// Tell libghostty whether a surface is currently visible. On visible,
    /// force a repaint so a re-shown pane presents a clean full frame.
    func setVisible(_ visible: Bool, for terminalID: PaneSlotID) {
        guard let handle = surfaces[terminalID] else { return }
        handle.setVisible(visible)
        if visible {
            handle.refresh()
        }
    }

    /// Force a full repaint for a visible or soon-to-be-visible surface.
    func refreshSurface(for terminalID: PaneSlotID) {
        surfaces[terminalID]?.refresh()
    }

    /// Returns the terminal's current text selection as a `String`, or
    /// `nil` when the surface is unknown or has no selection. Caps the
    /// UTF-8 copy at 4 KB since the only caller sanitizes+truncates to
    /// 100 characters — a multi-megabyte `cat` selection would otherwise
    /// force a full UTF-8 validation and `String` copy.
    func readSelection(for terminalID: PaneSlotID) -> String? {
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
    func setFocus(_ terminalID: PaneSlotID) {
        for (id, handle) in surfaces {
            if id == terminalID {
                handle.setVisible(true)
                handle.refresh()
            }
            handle.setFocus(id == terminalID)
        }
    }

    /// Whether any of the given terminals has a process that requires confirmation before quit.
    func needsConfirmQuit(terminalIDs: [PaneSlotID]) -> Bool {
        terminalIDs.contains { surfaces[$0]?.needsConfirmQuit == true }
    }

    /// Request close on each named surface and drop our reference. The surface itself
    /// is freed when the last strong reference to the `SurfaceHandle` drops.
    func destroySurfaces(terminalIDs: [PaneSlotID]) {
        for id in terminalIDs {
            destroySurface(terminalID: id)
        }
    }

    func destroySurface(terminalID: PaneSlotID) {
        if let scanner = portScanner {
            Task { await scanner.unregisterPane(terminalID) }
        }
        surfaces[terminalID]?.requestClose()
        forgetSurfaceRuntimeState(for: terminalID)
        killZmxSession(for: terminalID)
        forgetTrackingState(for: terminalID)
    }

    /// Soft destroy. Releases the libghostty surface (freeing scrollback
    /// + Metal layers via `SurfaceHandle.deinit`) and marks the leaf as
    /// rehydrated so a future surface creation re-attaches to the zmx
    /// session rather than re-running the default command. Unlike
    /// `destroySurface`, this preserves titles, PWDs, the
    /// pane→session map, and the `shellReadyFired` / `firstPaneMarkers`
    /// labels, and does NOT call `killZmxSession` or fire `paneClosed`.
    func evictSurface(terminalID: PaneSlotID) {
        if let handle = surfaces.removeValue(forKey: terminalID) {
            let size = GridSize(handle.queryGridSize())
            if size.cols > 0 && size.rows > 0 {
                evictedGridSizes[terminalID] = size
            }
            handle.requestClose()
        }
        rehydratedSurfaces.insert(terminalID)
        if let scanner = portScanner {
            Task { await scanner.unregisterPane(terminalID) }
        }
    }

    /// Mark a terminal as the first pane of its worktree — the pane whose
    /// creation caused the worktree to transition from `.closed` to
    /// `.running`. Called by the sidebar "Open" action (and any other
    /// caller that triggers a `.closed → .running` transition).
    func markFirstPane(_ terminalID: PaneSlotID) {
        firstPaneMarkers.insert(terminalID)
    }

    /// Mark a terminal as rehydrated from on-disk state at launch, rather
    /// than freshly opened by the user. Rehydrated panes never auto-run
    /// a default command — the command is presumed already running under
    /// zmx from the previous session. Called by
    /// `GrafttyApp.restoreRunningWorktrees` before creating surfaces.
    func markRehydrated(_ terminalID: PaneSlotID) {
        rehydratedSurfaces.insert(terminalID)
    }

    /// Drop the rehydration label so `defaultCommandDecision` treats a
    /// pane as fresh. Called by `clearRehydratedIfDaemonGone`.
    func clearRehydrated(_ terminalID: PaneSlotID) {
        rehydratedSurfaces.remove(terminalID)
    }

    /// Whether a terminal was marked as the first pane of its worktree.
    func isFirstPane(_ terminalID: PaneSlotID) -> Bool {
        firstPaneMarkers.contains(terminalID)
    }

    /// Whether a terminal was marked as rehydrated rather than user-opened.
    func wasRehydrated(_ terminalID: PaneSlotID) -> Bool {
        rehydratedSurfaces.contains(terminalID)
    }

    /// Clear per-terminal tracking state on destroy. Keeps the three
    /// tracking sets in sync with live surfaces so destroyed IDs don't
    /// leak memory or cause stale answers from the marker queries.
    private func forgetTrackingState(for terminalID: PaneSlotID) {
        shellReadyFired.remove(terminalID)
        firstPaneMarkers.remove(terminalID)
        rehydratedSurfaces.remove(terminalID)
        evictedGridSizes.removeValue(forKey: terminalID)
        forgetPaneSession(for: terminalID)
    }

    /// Resolve the per-surface zmx spawn parameters for a terminal pane.
    /// Returns nil when no launcher is configured or the binary is
    /// missing — in which case `SurfaceHandle` falls back to libghostty's
    /// default `$SHELL` spawn (existing pre-zmx behavior).
    func resolveZmxSpawnConfiguration(
        for terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String
    ) -> ZmxSpawnConfiguration? {
        guard let launcher = zmxLauncher, launcher.isAvailable else {
            return nil
        }
        let processEnv = ProcessInfo.processInfo.environment
        return ZmxSpawnConfiguration.make(
            launcher: launcher,
            paneSessionID: paneSessionID,
            worktreePath: worktreePath,
            socketPath: socketPath,
            processEnv: processEnv,
            bundleURL: Bundle.main.bundleURL,
            ghosttyResourcesDir: processEnv["GHOSTTY_RESOURCES_DIR"],
            agentHooksDisabled: processEnv["GRAFTTY_DISABLE_AGENT_HOOKS"] == "1",
            agentHooksRoot: AgentHookInstaller.rootDirectory()
        )
    }

    /// Fire-off the `zmx kill` for a terminal's session. Dispatched off
    /// the main thread because subprocess wait can take tens of ms; we
    /// don't want to block UI. Result is intentionally ignored — kill of
    /// an already-gone session is the success outcome.
    private func killZmxSession(for terminalID: PaneSlotID) {
        guard let launcher = zmxLauncher, launcher.isAvailable else { return }
        guard let name = zmxSessionName(for: terminalID) else { return }
        DispatchQueue.global(qos: .utility).async {
            launcher.kill(sessionName: name)
        }
    }

    func recordPaneSession(_ paneSessionID: PaneSessionID, for terminalID: PaneSlotID) {
        forgetPaneSession(for: terminalID)
        paneSessionIDs[terminalID] = paneSessionID
        paneSlotIDsBySessionName[ZmxLauncher.sessionName(for: paneSessionID)] = terminalID
    }

    func zmxSessionName(for terminalID: PaneSlotID) -> String? {
        guard let sessionID = paneSessionIDs[terminalID] else { return nil }
        return ZmxLauncher.sessionName(for: sessionID)
    }

    /// TERM-11.4: the last remote client detached from `sessionName`; give
    /// any still-silent pane on that session the chance to sync its PTY to
    /// the current grid.
    func remoteClientsDetached(fromSession sessionName: String) {
        for handle in surfaces.values where handle.zmxSessionName == sessionName {
            handle.remoteClientsDidDetach()
        }
    }

    private func forgetPaneSession(for terminalID: PaneSlotID) {
        guard let sessionID = paneSessionIDs.removeValue(forKey: terminalID) else { return }
        paneSlotIDsBySessionName.removeValue(forKey: ZmxLauncher.sessionName(for: sessionID))
    }

    /// Resolve `GHOSTTY_RESOURCES_DIR` before `ghostty_init` (CONFIG-2.x).
    /// An explicit env setting wins (CONFIG-2.2); otherwise point at the
    /// copy vendored in GrafttyKit's resource bundle (CONFIG-2.3/2.5) so
    /// shell integration never depends on a separately installed
    /// Ghostty.app. libghostty reads the variable to locate its
    /// shell-integration scripts; `resolveZmxSpawnConfiguration` and `WebSession`
    /// read it when constructing spawn environments.
    private static func pointAtGhosttyResources() {
        switch GhosttyRuntimeResources.resolve(
            processEnv: ProcessInfo.processInfo.environment,
            bundledDir: GhosttyRuntimeResources.bundledResourcesDir()
        ) {
        case .environmentOverride:
            break
        case .bundled(let dir):
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        case .unavailable:
            // CONFIG-2.4: warn visibly (not today's silent skip) and
            // degrade gracefully — shells still work, OSC 7/133-driven
            // features go quiet, TERM falls back per ZMX-6.5.
            NSLog("[Graftty] vendored ghostty resources missing from GrafttyKit bundle; shell integration disabled")
        }
    }

    /// Snapshot the given leaf's position inside a worktree's tree so we
    /// can restore it later. Called just before removing the leaf.
    func rememberPosition(
        terminalID: PaneSlotID,
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
        terminalID: PaneSlotID,
        worktreePath: String
    ) -> SplitTree.LeafPosition? {
        rememberedPositions[PaneHistoryKey(terminalID: terminalID, worktreePath: worktreePath)]
    }

    /// Drop the breadcrumb (optional cleanup on successful rejoin — keeps
    /// the map from growing unboundedly if a pane bounces a lot).
    func forgetPosition(terminalID: PaneSlotID, worktreePath: String) {
        rememberedPositions.removeValue(forKey: PaneHistoryKey(terminalID: terminalID, worktreePath: worktreePath))
    }

    /// Resolve a libghostty `ghostty_target_s` back to an Graftty `PaneSlotID`
    /// via the surface's userdata box. Returns nil for app-scoped targets or
    /// when the surface pointer has no box attached (shouldn't happen for
    /// surfaces we created).
    private func terminalID(from target: ghostty_target_s) -> PaneSlotID? {
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
            recordTitle(title, for: id)

        case GHOSTTY_ACTION_PWD:
            guard let id = terminalID(from: target) else { return }
            guard let pwdPtr = action.action.pwd.pwd else { return }
            let pwd = String(cString: pwdPtr)
            // Feeds `displayTitle(for:)`'s PWD-basename fallback.
            recordPWD(pwd, for: id)
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

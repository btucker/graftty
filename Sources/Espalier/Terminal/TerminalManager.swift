import AppKit
import GhosttyKit
import EspalierKit
@preconcurrency import UserNotifications

/// Four-way pane split request — carries enough information for the host to
/// pick both the `SplitDirection` (horizontal/vertical) and the placement
/// (new pane before or after the target). The context menu emits these;
/// `EspalierApp` translates them into `SplitTree.inserting(_:…)` /
/// `insertingBefore(_:…)` calls.
enum PaneSplit {
    case right, left, down, up
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
    private var wakeupObserver: NSObjectProtocol?

    /// Set by `EspalierApp` at startup. When non-nil and `isAvailable`,
    /// every new surface spawns `zmx attach <session> $SHELL` so the
    /// session survives Espalier quits. When nil or unavailable, surfaces
    /// fall back to libghostty's default $SHELL spawn.
    var zmxLauncher: ZmxLauncher?

    /// Theme colors pulled from the ghostty config (background, foreground).
    /// Emitted post-`initialize()` once the config is read; defaults to
    /// `.fallback` before that so views have something to render with.
    @Published var theme: GhosttyTheme = .fallback

    /// Per-pane titles set by the running program via the OSC-0/OSC-2 escape
    /// sequences (e.g. `\033]0;TITLE\007`). Populated in response to
    /// `GHOSTTY_ACTION_SET_TITLE`; cleaned up on `destroySurface`. Not
    /// persisted — these are ephemeral runtime state that die with their
    /// shell. The sidebar observes this to render pane labels.
    @Published var titles: [TerminalID: String] = [:]

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
    /// bindings). The host (EspalierApp) wires this up to mutate AppState and
    /// spawn a new surface; without it, split requests no-op.
    var onSplitRequest: ((TerminalID, PaneSplit) -> Void)?

    /// Called when libghostty asks the host to close a surface (shell exited,
    /// or user-initiated request-close that's been confirmed). The host
    /// removes the pane from the split tree and calls `destroySurface`.
    /// Without this wired, the surface lingers and the pane appears hung.
    var onCloseRequest: ((TerminalID) -> Void)?

    /// Called when a shell reports a new working directory (OSC 7 →
    /// `GHOSTTY_ACTION_PWD`). The host decides whether to re-home the
    /// pane under a different worktree in the sidebar based on which
    /// worktree path is the longest prefix of the new PWD.
    var onPWDChange: ((TerminalID, String) -> Void)?

    /// Called on shell-integration "command finished" events (requires
    /// ghostty shell integration to be sourced, which our env injection
    /// takes care of when Ghostty.app's resources are available). The
    /// host maps this to the worktree's attention badge — errors become
    /// red badges, long successful commands become subtle pings so the
    /// user knows the pane is idle again.
    var onCommandFinished: ((TerminalID, _ exitCode: Int16, _ duration: UInt64) -> Void)?

    /// Called on OSC 9;4 progress reports from programs like `git clone`
    /// or `apt` that advertise progress. The host updates the attention
    /// badge so the user can keep tabs on long-running jobs without
    /// staying on the pane.
    var onProgressReport: ((TerminalID, ProgressReport) -> Void)?

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

    /// Path to the Espalier control socket, exposed to spawned shells via `ESPALIER_SOCK`.
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
        // without this Espalier shells are "dumb" — no auto-PWD reporting,
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
    }

    /// Create surfaces for every leaf in the given split tree that does not yet
    /// have a surface. Returns the subset that was newly created.
    @discardableResult
    func createSurfaces(
        for splitTree: SplitTree,
        worktreePath: String
    ) -> [TerminalID: SurfaceHandle] {
        guard let app = ghosttyApp?.app else { return [:] }

        var created: [TerminalID: SurfaceHandle] = [:]
        for terminalID in splitTree.allLeaves where surfaces[terminalID] == nil {
            let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
            let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath,
                zmxInitialInput: zmxInitialInput,
                zmxDir: zmxDir,
                terminalManager: self
            )
            surfaces[terminalID] = handle
            created[terminalID] = handle
        }
        return created
    }

    /// Create a single surface, or return the existing one for this `TerminalID`.
    func createSurface(
        terminalID: TerminalID,
        worktreePath: String
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        if let existing = surfaces[terminalID] {
            return existing
        }

        let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
        let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxInitialInput: zmxInitialInput,
            zmxDir: zmxDir,
            terminalManager: self
        )
        surfaces[terminalID] = handle
        return handle
    }

    /// Look up the `NSView` hosting a given terminal's surface.
    func view(for terminalID: TerminalID) -> NSView? {
        surfaces[terminalID]?.view
    }

    /// Look up the `SurfaceHandle` for a given terminal.
    func handle(for terminalID: TerminalID) -> SurfaceHandle? {
        surfaces[terminalID]
    }

    /// Focus exactly one surface (by ID); unfocus the rest.
    func setFocus(_ terminalID: TerminalID) {
        for (id, handle) in surfaces {
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
            surfaces[id]?.requestClose()
            surfaces.removeValue(forKey: id)
            titles.removeValue(forKey: id)
            killZmxSession(for: id)
        }
    }

    func destroySurface(terminalID: TerminalID) {
        surfaces[terminalID]?.requestClose()
        surfaces.removeValue(forKey: terminalID)
        titles.removeValue(forKey: terminalID)
        killZmxSession(for: terminalID)
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
        return (
            launcher.attachInitialInput(sessionName: session, userShell: userShell),
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

    /// Resolve a libghostty `ghostty_target_s` back to an Espalier `TerminalID`
    /// via the surface's userdata box. Returns nil for app-scoped targets or
    /// when the surface pointer has no box attached (shouldn't happen for
    /// surfaces we created).
    private func terminalID(from target: ghostty_target_s) -> TerminalID? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return nil }
        let box = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
        return box.terminalID
    }

    /// Handles libghostty actions. We dispatch only the tags Espalier
    /// currently cares about; unknown tags are a silent no-op so libghostty
    /// upgrades don't force immediate handling of new actions.
    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let id = terminalID(from: target) else { return }
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            titles[id] = title

        case GHOSTTY_ACTION_PWD:
            guard let id = terminalID(from: target) else { return }
            guard let pwdPtr = action.action.pwd.pwd else { return }
            let pwd = String(cString: pwdPtr)
            onPWDChange?(id, pwd)

        case GHOSTTY_ACTION_RING_BELL:
            // Default system alert sound. Visual bell (a brief flash) is a
            // nice follow-up but not essential for parity with Ghostty's
            // default behavior.
            NSSound.beep()

        case GHOSTTY_ACTION_OPEN_URL:
            let url = action.action.open_url
            guard let urlPtr = url.url else { return }
            let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(url.len))
            guard let urlString = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8),
                  let parsed = URL(string: urlString)
            else { return }
            NSWorkspace.shared.open(parsed)

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
    /// "Espalier broken."
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

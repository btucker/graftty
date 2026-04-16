import AppKit
import GhosttyKit
import EspalierKit

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
            let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath
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

        let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath
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
        }
    }

    func destroySurface(terminalID: TerminalID) {
        surfaces[terminalID]?.requestClose()
        surfaces.removeValue(forKey: terminalID)
    }

    /// Handles libghostty actions (split requests, title changes, etc.).
    /// Stubbed for now; higher layers will wire this up to the split tree.
    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) {
        // TODO: dispatch on action.tag once the UI layer owns the model.
    }
}

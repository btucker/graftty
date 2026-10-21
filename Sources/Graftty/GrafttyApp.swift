import SwiftUI
import AppKit
import CryptoKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Keeps handler installation and listener publication in one ordered call.
/// The listener closure must remain last because `SocketServer.start()`
/// resumes its accept source before returning.
enum SocketServerStartup {
    static func start(
        server: SocketServer,
        onMessage: @escaping (NotificationMessage) -> Void,
        onAsyncRequest: @escaping @MainActor @Sendable
            (NotificationMessage) async -> ResponseMessage?,
        startListener: (SocketServer) throws -> Void = { try $0.start() }
    ) rethrows {
        server.onMessage = onMessage
        server.onAsyncRequest = onAsyncRequest
        try startListener(server)
    }
}

func defaultBranchStatus(
    for repo: RepoEntry,
    stats: WorktreeStats?
) -> WebServer.RepoInfo.DefaultBranchStatus? {
    guard let stats, stats.behind > 0,
          let defaultRef = stats.upstreamRefs?.defaultRef,
          defaultRef.hasPrefix("origin/") else {
        return nil
    }
    let branchName = String(defaultRef.dropFirst("origin/".count))
    guard !branchName.isEmpty,
          repo.worktrees.first(where: { $0.path == repo.path })?.branch == branchName else {
        return nil
    }
    return WebServer.RepoInfo.DefaultBranchStatus(
        branchName: branchName,
        remoteRef: defaultRef,
        behindCount: stats.behind
    )
}

protocol CodexAppServerDeliveryTrigger: Sendable {
    func onMessageArrival(team: String, worktree: String) async
}

extension CodexAppServerDeliveryService: CodexAppServerDeliveryTrigger {}
extension ClaudePeerDeliveryService: CodexAppServerDeliveryTrigger {}

private final class LivePaneSessionNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func replace(with names: Set<String>) {
        lock.lock()
        self.names = names
        lock.unlock()
    }

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name)
    }
}

struct AppTeamDeliveryLiveness: TeamDeliveryLivenessChecking {
    let livePaneSession: @Sendable (String) -> Bool
    let processStartTimeMicroseconds: @Sendable (Int32) -> Int64?

    func isLivePaneSession(_ sessionName: String) -> Bool {
        livePaneSession(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimeMicroseconds(pid)
    }
}

/// Seam for the `.showPane` route so tests can inject a canned scrollback
/// without spawning a `zmx` subprocess.
protocol ZmxHistoryReader: Sendable {
    func history(sessionName: String) throws -> String
}

struct ZmxHistorySubprocessReader: ZmxHistoryReader {
    let launcher: ZmxLauncher

    func history(sessionName: String) throws -> String {
        let result = try ZmxRunner.captureAll(
            executable: launcher.executable,
            args: ["history", sessionName],
            env: launcher.subprocessEnv(from: ProcessInfo.processInfo.environment),
            timeout: 1.0
        )
        guard result.exitCode == 0 else {
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty
                ? "zmx history failed"
                : "zmx history failed: \(trimmed)"
            throw NSError(
                domain: "ZmxHistorySubprocessReader",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return result.stdout
    }
}

/// Seam for `handleSendPane`: production binds to the acknowledged
/// `SurfaceHandle.writeText` path. Tests inject a recording stub without
/// driving a libghostty surface.
protocol PaneInputSink: AnyObject {
    func send(text: String, pressEnter: Bool) -> Bool
}

final class SurfaceHandlePaneInputSink: PaneInputSink {
    let handle: SurfaceHandle
    init(handle: SurfaceHandle) { self.handle = handle }
    /// Send-pane IPC is programmatic input arriving from another
    /// process — leave the IOS-12.1 silent gate closed so the next
    /// human keystroke at the target pane is what engages.
    func send(text: String, pressEnter: Bool) -> Bool {
        handle.writeText(
            text + (pressEnter ? "\r" : ""),
            claimEngagement: false
        )
    }
}

/// Fallback for a pane whose persisted zmx daemon is live but whose
/// in-memory Ghostty surface is absent.
protocol ZmxPaneInputWriter: Sendable {
    func send(sessionName: String, text: String) throws
}

struct ZmxPaneInputSubprocessWriter: ZmxPaneInputWriter {
    let launcher: ZmxLauncher

    func send(sessionName: String, text: String) throws {
        try launcher.send(sessionName: sessionName, text: text, timeout: 1.0)
    }
}

@main
struct GrafttyApp: App {
    // Keep this in menu order: the first host action for a chord wins.
    private static let macHostShortcutCommands =
        GhosttyCommandRegistry.macSplitActions
        + GhosttyCommandRegistry.macPaneFocusActions
        + GhosttyCommandRegistry.macPaneLayoutActions
        + GhosttyCommandRegistry.macPaneLifecycleActions
        + GhosttyCommandRegistry.macZoomActions
        + GhosttyCommandRegistry.macSettingsActions

    @State var appState: AppState
    @StateObject var terminalManager: TerminalManager
    @StateObject private var webController: WebServerController
    @StateObject private var updaterController: UpdaterController
    let services: AppServices
    /// Same `TrustedPeerStore` instance the coordinator and
    /// `WebRTCHostAgent` share — `PairedDevicesSection` reads it directly
    /// (list/remove) since the coordinator doesn't expose it publicly.
    private let trustedPeerStore: TrustedPeerStore
    private let hostKey: Curve25519.Signing.PrivateKey?
    /// Same `SSHConnectionRegistry` instance `WebRTCHostAgent` registers
    /// its live SSH connection into (REMOTE-3.1 revocation, W4). Exposed
    /// alongside `trustedPeerStore` so `PairedDevicesSection`'s "Remove"
    /// action can call `registry.revoke(deviceID:)` right after removing
    /// the peer from `trustedPeerStore` — closing the live connection
    /// immediately rather than waiting for the peer's next userauth
    /// attempt to fail.
    private let sshConnectionRegistry: SSHConnectionRegistry

    /// Observable proxy for per-pane port bindings. Mutated by the
    /// `PortScanner` `onChange` callback; injected into the SwiftUI
    /// environment so `SidebarView` can render port chips on each row.
    @StateObject private var portBindingsModel = PortBindingsModel()

    /// Polls `lsof` against each registered pane's process subtree to
    /// detect listening sockets. Wired into `TerminalManager` so pane
    /// add/close flows propagate registration; tick cadence is driven
    /// by `portsTicker`.
    private let portScanner = PortScanner(
        runner: SystemLsofRunner(),
        walker: ProcessTreeWalker()
    )

    /// 2s cadence for `portScanner.tick()`. A user starting `npm run
    /// dev` should see the chip appear within a couple seconds without
    /// the chip noticeably flickering on/off across rebuilds.
    private let portsTicker = PollingTicker(interval: .seconds(2), pauseWhenInactive: { false })

    // SwiftUI re-fires `.onAppear` on dock-reopen and File → New Window
    // because the WindowGroup content closure reruns; `startup()` is
    // one-time-per-launch (ghostty_init, pollers, observers). LAYOUT-5.3.
    @State private var didStartup = false

    init() {
        // Graftty is single-instance: the state.json, the graftty.sock
        // listener, and (most visibly) the per-pane zmx session names are
        // shared-global resources keyed off paths that don't vary between
        // app instances. Two Grafttys both attached to the same zmx
        // session will both echo the shell's output and both forward
        // keystrokes into the same PTY. Rather than isolate those three
        // resources per-instance (large refactor), we enforce one-at-a-time
        // here. Launch Services already dedupes normal Dock/Spotlight
        // opens; this guard catches `open -n` and same-bundle-id dev
        // relaunches.
        Self.terminateIfAnotherInstanceIsRunning()

        // ZMX-7.4: If Graftty.app was launched from a terminal that
        // was itself inside a zmx session, `ZMX_SESSION=<parent-name>`
        // is in the app's env. Host-managed native panes now route zmx
        // attach through `ZmxSpawnConfiguration`, which strips this per
        // spawn, but the app also launches other subprocesses. Strip the
        // leaky key globally before any surface or helper process spawns.
        ZmxLauncher.sanitizeProcessEnvironment()

        // Must run before any @AppStorage binding reads `teamEventRoutingPreferences`
        // (specifically the matrix in AgentTeamsSettingsPane) so SwiftUI binds
        // to the migrated value, not the default. TEAM-1.10.
        SettingsKeyMigration.run()

        // Must run before any UserDefaults read so non-binding readers see
        // the same defaults as @AppStorage. TEAM-1.6.
        var registeredDefaults = DefaultPrompts.registrations
        registeredDefaults[SettingsKeys.agentTeamsEnabled] = true
        UserDefaults.standard.register(defaults: registeredDefaults)

        let loaded = AppState.loadOrFreshBackingUpCorruption(from: AppState.defaultDirectory)
        _appState = State(initialValue: loaded)

        let socketPath = AppState.defaultDirectory.appendingPathComponent("graftty.sock").path
        let terminalManager = TerminalManager(socketPath: socketPath)
        _terminalManager = StateObject(wrappedValue: terminalManager)
        let pairingAdmission = HostPairingAdmission()
        let appServices = AppServices(
            socketPath: socketPath,
            pairingAdmission: pairingAdmission
        )
        services = appServices

        // Web access server — reconstruct the same zmx paths that `startup()`
        // computes so the WebServerController's child `zmx attach` invocations
        // hit the same ZMX_DIR as panes spawned from the app UI. Keeping the
        // path derivation here (rather than routing it through AppServices)
        // keeps the controller's lifetime tied to the SwiftUI App via
        // @StateObject, which is what Settings scene re-entry expects.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Graftty", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        let zmxExe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let webController = WebServerController(
            settings: WebAccessSettings.shared,
            zmxExecutable: zmxExe,
            zmxDir: zmxDir,
            displayOwnershipStore: appServices.displayOwnershipStore
        )
        _webController = StateObject(wrappedValue: webController)
        _updaterController = StateObject(wrappedValue: UpdaterController())

        // Load identity before startup creates the inbound host pool. The dedicated
        // paired-access listener authenticates v2 offers with the device keys
        // before passing them to the pool, whose agents open SSH sessions over the
        // resulting DataChannel → zmx attach.
        let hostIdentityStore = HostIdentityStore(directory: HostIdentityStore.defaultDirectory)
        let trustedPeerStore = TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory)
        self.trustedPeerStore = trustedPeerStore
        let sshConnectionRegistry = SSHConnectionRegistry()
        self.sshConnectionRegistry = sshConnectionRegistry

        do {
            self.hostKey = try hostIdentityStore.loadOrGenerateAndPersist()
        } catch {
            self.hostKey = nil
            NSLog("[Graftty] failed to load remote host identity: \(error)")
        }
    }

    /// If another Graftty process with our `CFBundleIdentifier` is
    /// already running, bring it to the front and exit our own process
    /// before any state, sockets, or zmx clients are created. Uses
    /// `exit(0)` instead of `NSApp.terminate` because we run before
    /// NSApplication has an app delegate, and because we have no
    /// allocated resources that need graceful teardown yet.
    private static func terminateIfAnotherInstanceIsRunning() {
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.graftty.app"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPID }
        guard let existing = others.first else { return }
        existing.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: services.statsStore,
                prStatusStore: services.prStatusStore,
                claudeSessionRegistry: services.claudeSessionRegistry,
                remoteBranchStore: services.remoteBranchStore,
                worktreeMonitor: services.worktreeMonitor,
                teamEventDispatcher: services.teamEventDispatcher,
                hostPairingCoordinator: services.hostPairingCoordinator,
                remoteMacsModel: services.remoteMacsModel,
                makeRemoteMacPairingDriver: services.remoteMacPairingDriverFactory
            )
                .environmentObject(webController)
                .environmentObject(updaterController)
                .environmentObject(portBindingsModel)
                .onAppear {
                    guard !didStartup else { return }
                    didStartup = true
                    startup()
                }
                .onChange(of: appState) { _, newState in
                    Self.persistAppState(newState)
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        // Hide the macOS title bar so the breadcrumb row sits directly
        // under the traffic lights — Andy wanted a terminal-multiplexer
        // look, not a generic Cocoa app frame. Content can flow under
        // the title bar area; MainWindow leaves ~72pt of leading space
        // on the breadcrumb for the traffic lights.
        .windowStyle(.hiddenTitleBar)
        // Default size only. Restoration of the exact saved frame is handled
        // by WindowFrameTracker (see MainWindow), which applies the saved
        // NSWindow.frame directly after the window is created. We cannot use
        // SwiftUI's `.defaultPosition(_:)` for this because on macOS 14 it
        // takes a UnitPoint (normalized 0..1), not pixel coordinates — passing
        // pixel values is silently a no-op.
        .defaultSize(width: 1400, height: 900)
        .commands {
            let hostShortcutsByAction = NavigationCommandShortcutPolicy.hostShortcutWinners(
                commands: Self.macHostShortcutCommands,
                bridge: terminalManager.keybindBridge
            )

            CommandGroup(after: .newItem) {
                // "Add Repository..." keeps its hardcoded Cmd+Shift+O —
                // it's an Graftty-specific action with no Ghostty equivalent.
                Button("Add Repository...") {
                    // MainWindow handles the file picker via its own button.
                    // This menu item is a placeholder for the standard shortcut.
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                AddWorktreeCommandButton()

                Divider()

                ForEach(GhosttyCommandRegistry.macSplitActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                ForEach(NavigationCommandShortcutPolicy.fixedPaneCommands, id: \.label) { command in
                    if let shortcut = KeyboardShortcutFromChord.shortcut(from: command.chord) {
                        Button(command.label) {
                            handleNavigateTreeOrder(forward: command.forward)
                        }
                        .keyboardShortcut(shortcut)
                    } else {
                        Button(command.label) {
                            handleNavigateTreeOrder(forward: command.forward)
                        }
                    }
                }

                ForEach(GhosttyCommandRegistry.macPaneFocusActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                WorktreeNavCommandButtons()

                Divider()

                ForEach(GhosttyCommandRegistry.macPaneLayoutActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }

                Divider()

                ForEach(GhosttyCommandRegistry.macPaneLifecycleActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }
            }

            CommandGroup(after: .toolbar) {
                ForEach(GhosttyCommandRegistry.macZoomActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                    .disabled(terminalManager.focusedTerminalID == nil)
                }
            }

            // TEAM-7.1: *Window → Team Activity Log* opens the activity
            // window for the focused worktree's team. Disabled when the
            // current selection has no team (single-worktree repo or
            // teams disabled). The button is hosted inside a tiny View
            // wrapper so it can read the `\.openWindow` environment
            // value, which is unavailable directly inside `.commands`.
            CommandGroup(after: .windowList) {
                TeamActivityLogMenuButton(appState: $appState)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdatesWithUI()
                }
                .disabled(!updaterController.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updaterController.automaticallyChecksForUpdates },
                    set: { updaterController.automaticallyChecksForUpdates = $0 }
                ))

                Divider()

                Button("Install CLI Tool...") {
                    installCLI()
                }
                ForEach(GhosttyCommandRegistry.macSettingsActions, id: \.action) { command in
                    bridgedButton(command, shortcutsByAction: hostShortcutsByAction) {
                        handleGhosttyCommand(command)
                    }
                }
            }
        }

        // Settings scene — General pane, Web Access pane, and the unified
        // Agent Teams pane (absorbs Channels). WebServerController is injected
        // so WebSettingsPane can read `.status` / `.currentURL`, and so
        // toggling `WebAccessSettings.isEnabled` triggers the controller's
        // `reconcile()` via its Combine subscription.
        Settings {
            TabView {
                SettingsView(
                    updaterController: updaterController,
                    idleSleepController: services.idleSleepController,
                    onRestartZMX: { restartZMXWithConfirmation() },
                    editorPreference: terminalManager.editorPreference
                )
                    .tabItem { Label("General", systemImage: "gear") }
                WebSettingsPane(
                    pairingCoordinator: services.hostPairingCoordinator,
                    trustedPeerStore: trustedPeerStore,
                    sshConnectionRegistry: sshConnectionRegistry
                )
                    .environmentObject(webController)
                    .tabItem { Label("Web Access", systemImage: "network") }
                AgentTeamsSettingsPane()
                    .tabItem { Label("Agent Teams", systemImage: "person.2.fill") }
            }
        }

        // TEAM-7.1: Team Activity Log window. Opened via the *Window*
        // menu command (TEAM-7.1) and the sidebar's worktree-row
        // context menu (TEAM-7.2). The window's `for:` value is a
        // `TeamActivityLogWindowID` (Hashable+Codable) so SwiftUI can
        // route `openWindow(id:value:)` invocations and so each team
        // gets its own window instance keyed by team ID.
        WindowGroup(
            "Team Activity Log",
            id: TeamActivityLogWindowID.windowGroupID,
            for: TeamActivityLogWindowID.self
        ) { $boundID in
            if let boundID {
                TeamActivityLogWindow(
                    rootDirectory: AppState.defaultDirectory
                        .appendingPathComponent("team-inbox", isDirectory: true),
                    teamID: boundID.teamID,
                    teamName: boundID.teamName
                )
            } else {
                Text("No team selected.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
    }

    /// Window-scoped `.onChange` handles normal UI mutations. Background
    /// services also call this directly because they remain active after the
    /// last window closes and therefore cannot rely on a live view observer.
    static func persistAppState(_ state: AppState) {
        do {
            try state.save(to: AppState.defaultDirectory)
        } catch {
            // Silently dropping this error means a full disk, read-only
            // `$HOME`, or permissions clash silently stops persistence.
            // STATE-6.2 / PERSIST-2.2.
            NSLog("[Graftty] AppState.save failed: %@", String(describing: error))
        }
    }

    /// @spec URL-2.1: When the macOS app opens a `graftty://open` URL
    /// that resolves to a tracked worktree, the application shall select
    /// that worktree, focus the resolved pane when one is present and the
    /// worktree is running, and bring the app to the foreground.
    private func handleDeepLink(_ url: URL) {
        guard Self.applyDeepLink(
            url,
            appState: $appState,
            admitWorktree: { terminalManager.wakeWorktree($0.path) },
            prepareRunningWorktree: { worktree in
                terminalManager.createSurfaces(
                    for: worktree.splitTree,
                    paneSessions: worktree.paneSessions,
                    worktreePath: worktree.path
                )
            }
        ) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func applyDeepLink(
        _ url: URL,
        appState: Binding<AppState>,
        admitWorktree: (WorktreeEntry) -> Bool = { _ in true },
        prepareRunningWorktree: (WorktreeEntry) -> Void
    ) -> Bool {
        guard let target = GrafttyDeepLink.parse(url),
              case let .resolved(path, paneSlot) = DeepLinkResolver.resolve(
                  target,
                  inRepos: appState.wrappedValue.repos
              ), let resolved = appState.wrappedValue.worktree(forPath: path),
              admitWorktree(resolved) else { return false }
        appState.wrappedValue.selectedWorktreePath = path
        if let worktree = appState.wrappedValue.worktree(forPath: path),
           worktree.state == .running {
            prepareRunningWorktree(worktree)
            if let paneSlot, worktree.paneSessions[paneSlot] != nil {
                appState.wrappedValue.setFocusedTerminal(paneSlot, forWorktreePath: path)
            }
        }
        return true
    }

    private func startup() {
        let zmxBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Graftty", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        let zmxLauncher = ZmxLauncher(executable: zmxBinary, zmxDir: zmxDir)
        terminalManager.zmxLauncher = zmxLauncher
        Task { @MainActor in
            await services.remoteMacsModel.loadSavedRemotes()
        }

        // TERM-11.5: pane backends consult the registry to decide whether
        // the IOS-12.1 silent gate applies (remote client attached to the
        // same zmx session).
        terminalManager.remoteAttachmentRegistry = services.remoteAttachmentRegistry
        terminalManager.displayOwnershipStore = services.displayOwnershipStore
        services.remoteAttachmentRegistry.onLastDetach = { [weak terminalManager] sessionName in
            // TERM-11.4: fires on the detaching connection's thread; hop to
            // the main actor where TerminalManager lives.
            Task { @MainActor in
                terminalManager?.remoteClientsDetached(fromSession: sessionName)
            }
        }

        // Hand the scanner to TerminalManager so pane add/close flows
        // propagate registration, then wire the scanner's onChange into
        // PortBindingsModel so SidebarView re-renders chips when a
        // pane's listening sockets change.
        terminalManager.portScanner = portScanner
        let tmRef = terminalManager
        Task { [portBindingsModel, tmRef] in
            await portScanner.setOnChange { [weak portBindingsModel] id, list in
                portBindingsModel?.set(id, list)
            }
            // PORTS-4.5: panes registered before zmx wrote their `pty
            // spawned` log line need their PID resolved later.
            // `[weak]` breaks the cycle through TerminalManager.portScanner.
            await portScanner.setPIDResolver { [weak tmRef = tmRef] id in
                await tmRef?.lookupShellPIDForPortScan(for: id)
            }
        }

        // 2s cadence for port-binding scans. Cheap (one batched lsof
        // across all registered shell PIDs per tick) and only meaningful
        // while the app is up, including while a mobile client is using it.
        portsTicker.start { [portScanner] in
            await portScanner.tick()
        }

        // Wrappers always go on PATH; the Agent Teams toggle is read inside
        // the wrapper at request time.
        Self.installAgentHookAssets()

        // Refresh previously installed plugins after app updates. First-time
        // installation still requires the launch offer's explicit consent.
        Task { @MainActor in
            await AgentPluginAutomaticUpdate.shared.runAtLaunch()
            AgentPluginInstallOfferPresenter.presentWhenWindowIsReady()
        }

        // One-shot cleanup of the retired graftty-channel MCP integration
        // (TEAM-8.1 / TEAM-8.2 / TEAM-8.3). Runs idempotently every launch
        // until we drop it in a few releases.
        Task { await LegacyChannelCleanup.run() }

        // Strip the legacy `--dangerously-load-development-channels
        // server:graftty-channel` substring from `defaultCommand` and
        // disclose the change once via NSAlert. Runs on the main actor
        // so the modal alert can sit on the run loop after `startup()`
        // returns (TEAM-8.4).
        Task { @MainActor in
            if LegacyChannelCleanup.scrubDefaultCommandLaunchFlag() {
                let alert = NSAlert()
                alert.messageText = "Legacy launch flag removed"
                alert.informativeText = "Removed --dangerously-load-development-channels server:graftty-channel from your default command. Agent teams now run via the unified hook adapter."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        if !zmxLauncher.isAvailable {
            DispatchQueue.main.async {
                ZmxFallbackBanner.presentIfNeeded()
            }
        }

        terminalManager.initialize()
        AgentNotificationRouter.shared.install()
        AgentNotificationRouter.shared.onActivate = { payload in
            NSApp.activate(ignoringOtherApps: true)
            AgentNotificationActivation.shared.enqueue(payload)
        }
        services.remoteMacsModel.onRemoteNotification = { [remoteMacsModel = services.remoteMacsModel] event in
            AgentNotificationRouter.shared.post(event, resolvingIdentity: {
                let identity = await remoteMacsModel.notificationProjectIdentity(for: event)
                return identity.flatMap { ProjectNotificationIdentity.image(project: $0.0, data: $0.1) }
            })
        }
        AgentNotificationRouter.shared.onActivateRemote = {
            [remoteMacsModel = services.remoteMacsModel] event in
            NSApp.activate(ignoringOtherApps: true)
            remoteMacsModel.activateRemoteNotification(event)
        }

        terminalManager.editorPreference = EditorPreference(
            defaults: .standard,
            shellEnvProbe: LoginShellEnvProbe()
        )

        // Route context-menu split requests through the same insertion code
        // path that Cmd+D uses, but targeting the *menu's* surface rather
        // than the currently-focused one — the two can differ if the user
        // right-clicks an unfocused pane.
        terminalManager.onSplitRequest = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .split(direction),
                    for: terminalID
                ) {
                    return
                }
                _ = Self.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: direction
                )
            }
        }

        terminalManager.onOpenInEditorPane = { [appState = $appState, tm = terminalManager] terminalID, initialInput in
            Task { @MainActor in
                _ = Self.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: .right,
                    extraInitialInput: initialInput
                )
            }
        }

        // TERM-8.10 / PWD-1.4: terminal surface menu and sidebar drag
        // both route through this callback to share the existing
        // PWD-2.x reassignment pipeline.
        terminalManager.onMovePane = { [appState = $appState, tm = terminalManager] terminalID, destinationPath in
            MainActor.assumeIsolated {
                Self.reassignPaneByPWD(
                    appState: appState,
                    terminalManager: tm,
                    terminalID: terminalID,
                    newPWD: destinationPath
                )
            }
        }

        // Surface menu (`SurfaceContextMenu`) calls this at right-click
        // time so the snapshot is fresh; nil makes it skip the Move
        // section (e.g. mid-reassignment race window).
        let paneMoveRemoteBranchStore = services.remoteBranchStore
        terminalManager.currentPaneMoveContext = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                let state = appState.wrappedValue
                let defaultBranches = PaneMoveMenuContext.defaultBranches(
                    for: state.repos,
                    using: paneMoveRemoteBranchStore
                )
                return PaneMoveMenuContext.resolve(
                    terminalID: terminalID,
                    appState: state,
                    shellCwd: tm.shellCwd(for: terminalID),
                    defaultBranchesByRepoPath: defaultBranches
                )
            }
        }

        // A user-issued close action targets the pane that emitted it.
        terminalManager.onCloseRequest = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(.close, for: terminalID) {
                    return
                }
                switch paneCloseAction() {
                case .closePane:
                    Self.closePane(
                        appState: appState,
                        terminalManager: tm,
                        targetID: terminalID,
                        userInitiated: true
                    )
                }
            }
        }

        // A surface can also disappear because its shell exited or, for a
        // host-managed proxy, its transport dropped. Keep that distinct from
        // user close so a network failure cannot kill the owning Mac's pane.
        terminalManager.onSurfaceClosed = {
            [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .surfaceClosed,
                    for: terminalID
                ) {
                    return
                }
                Self.closePane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID
                )
            }
        }

        terminalManager.onGotoSplit = { [appState = $appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .focus(direction),
                    for: terminalID
                ) {
                    return
                }
                Self.navigatePane(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    direction: direction
                )
            }
        }

        terminalManager.onGotoSplitOrder = { [appState = $appState, tm = terminalManager] terminalID, forward in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .focusOrder(forward: forward),
                    for: terminalID
                ) {
                    return
                }
                Self.navigatePaneInTreeOrder(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    forward: forward
                )
            }
        }

        terminalManager.onToggleZoom = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .toggleZoom,
                    for: terminalID
                ) {
                    return
                }
                Self.toggleZoom(appState: appState, on: terminalID)
            }
        }

        terminalManager.onResizeSplit = { [appState = $appState, tm = terminalManager] terminalID, direction, amount in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .resize(direction: direction, amount: amount),
                    for: terminalID
                ) {
                    return
                }
                Self.resizeSplit(
                    appState: appState,
                    target: terminalID,
                    direction: direction,
                    pixels: amount
                )
            }
        }

        terminalManager.onEqualizeSplits = { [appState = $appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                if tm.routeHostManagedPaneCommand(
                    .equalize,
                    for: terminalID
                ) {
                    return
                }
                Self.equalizeSplits(appState: appState, around: terminalID)
            }
        }

        // `ghostty_app_update_config` re-reads the config files and swaps
        // them into the live app; our bridge rebuild happens inside
        // `reloadGhosttyConfig`. TERM-9.1.
        terminalManager.onReloadConfig = { [tm = terminalManager] in
            MainActor.assumeIsolated {
                tm.reloadGhosttyConfig()
            }
        }

        // Ghostty keybind mapped to `open_config` → same flow as the
        // "Open Ghostty Settings" menu item: resolve the config path,
        // create it if missing, hand to NSWorkspace. TERM-9.2.
        terminalManager.onOpenConfig = {
            MainActor.assumeIsolated {
                Self.openGhosttySettings()
            }
        }

        // Shell integration semantic pings → sidebar attention badge on
        // the owning worktree. The badge is auto-clearing (3s) so it
        // behaves like a "ping", not a permanent state the user has to
        // dismiss. Non-zero exit codes get a longer (8s) dwell so the
        // user has a chance to notice errors across a worktree they're
        // not currently viewing.
        terminalManager.onCommandFinished = { [appState = $appState, registry = services.claudeSessionRegistry] terminalID, exitCode, _ in
            MainActor.assumeIsolated {
                if let indices = appState.wrappedValue.indicesOfWorktreeContaining(terminalID: terminalID),
                   let session = appState.wrappedValue.repos[indices.repo].worktrees[indices.worktree].paneSessions[terminalID] {
                    registry.removePane(ZmxLauncher.sessionName(for: session))
                }
                Self.setAttentionForTerminal(
                    appState: appState,
                    terminalID: terminalID,
                    text: exitCode == 0 ? "✓" : "!",
                    clearAfter: exitCode == 0 ? 3 : 8,
                    source: .commandFinished
                )
            }
        }
        // PROGRESS_REPORT intentionally unhandled — shell-integration
        // progress pings (OSC 9;4 from tools emitting indeterminate or
        // percent status) were too loud relative to the urgency they
        // convey. The underlying plumbing in TerminalManager stays
        // wired; we can revisit with a dedicated, less-aggressive
        // visual if the need comes back.

        // First prompt on a newly-ready pane → maybe type the user's
        // default command. `maybeRunDefaultCommand` consults UserDefaults
        // and the TerminalManager's first-pane / rehydration markers to
        // decide; most of the time it's a no-op.
        terminalManager.onShellReady = { [tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                Self.maybeRunDefaultCommand(
                    terminalManager: tm,
                    terminalID: terminalID
                )
            }
        }

        // Wire the AppState provider for the team PR-merged dispatch hook
        // (TEAM-5.4). @State is only accessible once SwiftUI's body has
        // run, so we capture a Binding here rather than in
        // AppServices.init().
        let channelAppStateBinding = $appState
        services.appStateProvider = { channelAppStateBinding.wrappedValue }

        // SocketServer already dispatches onMessage to the main queue.
        let binding = $appState
        let tm = terminalManager
        tm.autoSleep.start { binding.wrappedValue }
        let sleepCoordinator = tm.autoSleep.coordinator
        services.remoteAttachmentRegistry.wakeBeforeAttach = { session in
            sleepCoordinator.wake(session: session)
        }
        services.remoteAttachmentRegistry.wakeBeforeInput = { session in
            sleepCoordinator.wakeForInput(session: session)
        }
        let teamInbox = services.teamInbox
        let teamEventDispatcher = services.teamEventDispatcher
        let remoteTeamRouter = services.remoteTeamRouter
        tm.agentCompletionLoader = { currentWorktreePath, update in
            let repos = binding.wrappedValue.repos
            async let remote = remoteTeamRouter.members()
            let local = await OffMainIO.run {
                AgentCompletionCatalog.local(repos: repos,
                    records: (try? TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()).listAll()) ?? [],
                    isReachable: TeamAgentReachability.isReachable)
            }
            update?(AgentCompletionCatalog.contextualized(local, worktreePath: currentWorktreePath, repos: repos))
            return AgentCompletionCatalog.contextualized(local + AgentCompletionCatalog.remote(members: await remote),
                worktreePath: currentWorktreePath, repos: repos)
        }
        webController.setAgentCompletionsProvider { worktreeID in
            if let worktreeID, worktreeID.hasPrefix("relay-worktree-") {
                if case .agentCompletions(let candidates) = await services.remoteMacsModel
                    .sendRelayedWorktreeManagement(.worktreeAgentCompletions(worktreeID: worktreeID)) {
                    return candidates
                }
                return []
            }
            return await tm.agentCompletionLoader?(worktreeID, nil) ?? []
        }
        remoteTeamRouter.handler = { deviceID, data in
            do {
                let request = try JSONDecoder().decode(RemoteTeamRequest.self, from: data)
                if case .worktree(let operation) = request {
                    let remoteOrigin: WorktreeHistory.Origin?
                    if case .create(let creation) = operation { remoteOrigin = creation.historyOrigin() }
                    else { remoteOrigin = nil }
                    let response = await RemoteCLIWorktreeService.handle(
                        operation, from: deviceID, repos: binding.wrappedValue.repos,
                        status: { services.cliWorktreeCreations.status(operationID: $0) },
                        create: { message in
                            guard case let .createWorktree(caller, name, branch, existing, base, command, runtime, prompt, id) = message else {
                                return .error("Expected local worktree creation")
                            }
                            return await Self.beginCLIWorktreeCreation(
                                callerPath: caller, worktreeName: name, branchName: branch,
                                existing: existing, base: base, command: command,
                                agentRuntime: runtime, agentPrompt: prompt, operationID: id,
                                creationOrigin: remoteOrigin, appState: binding, terminalManager: tm,
                                teamInbox: teamInbox,
                                teamEventDispatcher: teamEventDispatcher,
                                worktreeMonitor: services.worktreeMonitor,
                                statsStore: services.statsStore,
                                worktreeCreations: services.cliWorktreeCreations)
                        })
                    return try JSONEncoder().encode(response)
                }
                let repos = binding.wrappedValue.repos
                let enabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
                let handler = RemoteTeamService(
                    inbox: teamInbox,
                    agentRecords: {
                        (try? TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()).listAll()) ?? []
                    },
                    agentReachability: { TeamAgentReachability.isReachable($0) }
                )
                let response = await OffMainIO.run {
                    handler.handle(request, from: deviceID, repos: repos, teamsEnabled: enabled)
                }
                return try JSONEncoder().encode(response)
            } catch {
                return (try? JSONEncoder().encode(RemoteTeamResponse.error("Invalid remote team request: \(error)"))) ?? Data()
            }
        }
        do {
            try SocketServerStartup.start(
                server: services.socketServer,
                onMessage: { message in
                    MainActor.assumeIsolated {
                        Self.handleNotification(
                            message,
                            appState: binding,
                            terminalManager: tm
                        )
                    }
                },
                onAsyncRequest: { message in
                    if case .remoteWorktree(let target, let request) = message {
                        return await remoteTeamRouter.worktree(target: target, request: request, repos: binding.wrappedValue.repos)
                    }
                    if case .reconnectRemoteClient(let target) = message {
                        return await remoteTeamRouter.reconnectClient(target: target)
                    }
                    if case .teamReply = message {
                        return await Self.handleTeamReply(
                            message, appState: binding, router: remoteTeamRouter,
                            inbox: teamInbox, dispatcher: teamEventDispatcher
                        )
                    }
                    if let response = await Self.handleRemoteTeamSend(
                        message, appState: binding, router: remoteTeamRouter
                    ) { return response }
                    let response = await Self.handlePaneRequest(
                        message,
                        appState: binding,
                        terminalManager: tm,
                        teamInbox: teamInbox,
                        teamEventDispatcher: teamEventDispatcher,
                        worktreeMonitor: services.worktreeMonitor,
                        statsStore: services.statsStore,
                        prStatusStore: services.prStatusStore,
                        worktreeCreations: services.cliWorktreeCreations,
                        worktreeRemovals: services.cliWorktreeRemovals,
                        remoteBranchStore: services.remoteBranchStore,
                        agentRegistry: services.claudeSessionRegistry,
                        remoteMacsModel: services.remoteMacsModel
                    )
                    return await remoteTeamRouter.includingRemoteMembers(in: response, for: message)
                }
            )
        } catch let error as SocketServerError {
            // Surface the failure in Console.app AND present a one-time
            // banner so the user sees it immediately rather than learning
            // about it later via a "not listening" CLI error (ATTN-3.4).
            NSLog("[Graftty] SocketServer.start() failed: %@", String(describing: error))
            DispatchQueue.main.async {
                NotifySocketBanner.presentIfNeeded(error: error)
            }
        } catch {
            NSLog("[Graftty] SocketServer.start() failed: %@", String(describing: error))
        }

        let attentionHandoff = AttentionFileHandoff()
        let attentionObserver = AttentionFileHandoffObserver(handoff: attentionHandoff)
        do {
            try attentionObserver.start {
                Task { @MainActor in
                    do {
                        try attentionHandoff.consumeActivities { activity in
                            switch activity {
                            case .progress(let event):
                                guard let index = binding.wrappedValue.indices(forWorktreePath: event.worktree) else { return }
                                if let input = event.userInput {
                                    binding.wrappedValue.repos[index.repo].worktrees[index.worktree].recordUserInput(input)
                                }
                                Self.clearAgentAttention(
                                    callerPath: event.worktree,
                                    callerAgentID: event.agentID,
                                    runtime: event.runtime,
                                    sessionID: event.sessionID,
                                    progressedAt: event.progressedAt,
                                    appState: binding
                                )
                            case .stop(let event):
                                guard binding.wrappedValue.worktree(forPath: event.worktree) != nil else { return }
                                if let pane = event.paneSessionName,
                                   binding.wrappedValue.worktree(forPath: event.worktree)?
                                    .paneSlot(forSessionName: pane) != nil {
                                    services.claudeSessionRegistry.recordHook(
                                        runtime: event.runtime, event: .stop,
                                        sessionID: event.sessionID ?? event.agentID,
                                        paneSessionName: pane, attentionReason: nil
                                    )
                                }
                                Self.recordStoppedTurn(
                                    callerPath: event.worktree, runtime: event.runtime,
                                    callerAgentID: event.agentID, sessionID: event.sessionID,
                                    paneSessionName: event.paneSessionName, recap: event.recap,
                                    stoppedAt: event.stoppedAt, appState: binding,
                                    terminalManager: tm
                                )
                            }
                            try binding.wrappedValue.save(to: AppState.defaultDirectory)
                        }
                    } catch {
                        NSLog("[Graftty] Attention file handoff failed: %@", String(describing: error))
                    }
                }
            }
            services.attentionFileObserver = attentionObserver
        } catch {
            NSLog("[Graftty] Attention file observer failed: %@", String(describing: error))
        }

        let remoteBranchStore = services.remoteBranchStore
        let prStatusStore = services.prStatusStore
        remoteBranchStore.onChange = { repoPath, old, new in
            guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
            RemoteBranchPRRefreshRouter.route(
                repo: repo,
                oldBranches: old,
                newBranches: new,
                clear: { prStatusStore.clear(worktreePath: $0) },
                pulseRepo: { prStatusStore.pulse(repoPath: $0) }
            )
        }

        let bridge = WorktreeMonitorBridge(
            appState: $appState,
            statsStore: services.statsStore,
            prStatusStore: services.prStatusStore,
            remoteBranchStore: services.remoteBranchStore
        )
        services.worktreeMonitorBridge = bridge
        services.worktreeMonitor.delegate = bridge
        for repo in appState.repos {
            services.worktreeMonitor.installRepoWatchers(repo: repo)
        }

        // Deleted worktrees remain visible for a one-hour recovery window:
        // transient filesystem events and same-path re-adds can resurrect
        // them during that time. The persisted `staleSince` timestamp makes
        // the deadline survive relaunches. Keep ticking in the background
        // because the deletion may occur while the user is working in a
        // different app; the next tick after wake handles system sleep. Do
        // not start its immediate first tick until launch reconciliation has
        // had a chance to resurrect or relocate recoverable stale entries.
        let staleWorktreeAutoDismissTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        let autoDismissPRStatusStore = services.prStatusStore
        let autoDismissStatsStore = services.statsStore
        services.staleWorktreeAutoDismissTicker = staleWorktreeAutoDismissTicker
        // Start the stats safety-net poller: HEAD and origin-ref events
        // provide the prompt path, while this 5s ticker catches
        // coalesced or missed filesystem events. Per-repo, it gates the
        // 30-second `git fetch` cadence (DIVERGE-4.3); otherwise it rotates
        // through four running worktrees per tick (DIVERGE-4.6 / PERF-1.11).
        // Keeps polling while Graftty is backgrounded (DIVERGE-4.8) —
        // the user's Claude / editor session is often in a different
        // frontmost app, and that's exactly when a `git add` in an
        // external shell or a merge on origin needs to show up in the
        // sidebar without requiring a click back into Graftty first.
        let statsTicker = PollingTicker(
            interval: .seconds(5),
            pauseWhenInactive: { false }
        )
        services.statsStore.start(
            ticker: statsTicker,
            getRepos: { binding.wrappedValue.repos },
            recordAutoTrackingAttempt: { path, target in
                guard let indices = binding.wrappedValue.indices(forWorktreePath: path) else { return }
                binding.wrappedValue.repos[indices.repo].worktrees[indices.worktree].autoTrackLastAttempt = target
                Self.persistAppState(binding.wrappedValue)
            }
        )

        // Local remote-ref scans seed PR polling's pushed-branch gate. Each
        // scan is one `git for-each-ref`, and the ticker rotates through four
        // repos per tick. PollingTicker fires immediately, so `start` seeds
        // the first batch without a second explicit refresh pass; onChange
        // pulses PR polling as results land.
        let remoteBranchTicker = PollingTicker(
            interval: .seconds(10),
            pauseWhenInactive: { false }
        )
        services.remoteBranchStore.start(
            ticker: remoteBranchTicker,
            getRepos: { binding.wrappedValue.repos }
        )

        // The PR poller drives `gh pr list`, a GraphQL call metered
        // against a separate 5,000-point/hour budget. Unlike the stats
        // poller's local `git fetch`, every tick here costs API quota,
        // so the per-repo cadence gate is 60s (see
        // `PRStatusStore.cadenceFor`) — a 5s cadence exhausted the
        // entire GraphQL budget on a single repo. The ticker keeps
        // firing while Graftty is backgrounded (PR-7.6): `gh pr list`
        // is the only channel for an open→merged transition that
        // happens on GitHub without a local `git fetch`, and at 60s the
        // background cost is genuinely negligible. The 60s cadence is a
        // per-repo eligibility floor; ordinary ticks rotate through four
        // repos at a time, so larger workspaces trade additional safety-net
        // latency for bounded query volume. Explicit pulses still cover every
        // repo, while remote-ref changes pulse only their affected repo.
        let prTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        services.prStatusStore.start(
            ticker: prTicker,
            getRepos: { binding.wrappedValue.repos }
        )

        // Poll `claude agents --json` on a fast cadence to derive per-pane
        // busy/idle liveness. The registry retains this ticker internally
        // (like prStatusStore), so the local var is sufficient — the
        // registry itself outlives startup() via AppServices.
        let claudeAgentsTicker = PollingTicker(interval: .seconds(2))
        services.claudeSessionRegistry.start(ticker: claudeAgentsTicker)

        // Sweep dangling presence files left behind by SIGKILL'd agents
        // whose wrapper trap never fired. The wrapper trap is the primary
        // cleanup path (TEAM-PRESENCE-1.3); this fallback runs on a slow
        // cadence and only deletes records whose recorded PID is no
        // longer alive per `kill(pid, 0)` semantics. Continues while
        // backgrounded for the same reason the stats poller does:
        // agent processes can die at any time and Graftty might not be
        // frontmost when it happens.
        let presenceTicker = PollingTicker(
            interval: .seconds(30),
            pauseWhenInactive: { false }
        )
        services.presenceCleanupTicker = presenceTicker
        let presenceStorage = TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        )
        let presenceIndex = TeamPresenceIndex(
            records: (try? presenceStorage.listAll()) ?? []
        )
        func refreshPresenceIndex() -> [TeamPresenceRecord] {
            let records = (try? presenceStorage.listAll()) ?? []
            presenceIndex.replace(with: records)
            return records
        }

        let livePaneSessionNames = LivePaneSessionNames()
        func refreshDeliveryLiveness(records: [TeamPresenceRecord]? = nil) {
            let records = records ?? refreshPresenceIndex()
            let names = Self.livePaneSessionNamesForAutomaticDelivery(
                records: records,
                terminalManager: tm
            )
            livePaneSessionNames.replace(with: names)
        }

        let deliveryLiveness = AppTeamDeliveryLiveness(
            livePaneSession: { livePaneSessionNames.contains($0) },
            processStartTimeMicroseconds: { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
        )
        let codexAppServerDeliveryService = CodexAppServerDeliveryService(
            inbox: services.teamInbox,
            presenceRecords: { (try? presenceStorage.listAll()) ?? [] },
            sessionStorage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            liveness: deliveryLiveness,
            client: CodexAppServerClient(),
            wakeBeforeDelivery: { sleepCoordinator.wake(path: $0) }
        )
        let claudeReplyBridge = ClaudePeerReplyBridge { original, recipient, reply in
            // The bridge binds a socket to the recipient that received the
            // original row. Refuse a reply after that exact session disappears.
            let reachable = await OffMainIO.run {
                let records = (try? presenceStorage.listAll()) ?? []
                return records.contains {
                    TeamAgentDirectory.identity(for: $0) == recipient.id && $0.worktree == recipient.worktreePath
                        && $0.transport == recipient.transport
                        && TeamAgentReachability.isReachable($0)
                }
            }
            guard reachable else { return .error("The replying Claude agent is no longer reachable") }
            return await Self.handleTeamReply(
                .teamReply(callerWorktree: recipient.worktreePath, callerAgentID: recipient.id.rawValue,
                           messageID: original.id, text: reply.body,
                           priority: reply.priority == .now ? .urgent : .normal),
                appState: binding, router: remoteTeamRouter, inbox: teamInbox,
                dispatcher: teamEventDispatcher
            )
        }
        let claudePeerDeliveryService = ClaudePeerDeliveryService(
            inbox: services.teamInbox,
            presenceRecords: { (try? presenceStorage.listAll()) ?? [] },
            agentReachability: { record in
                // The shared native-delivery predicate, closed over the same
                // liveness view the Codex service uses, so both services and
                // the hook-side default-agent computation agree on which
                // agent owns an untargeted head row.
                TeamAgentReachability.isReachableForNativeDelivery(
                    record,
                    liveness: deliveryLiveness
                )
            },
            replyBridge: claudeReplyBridge,
            wakeBeforeDelivery: { sleepCoordinator.wake(path: $0) }
        )
        presenceTicker.start {
            let records = await presenceIndex.refresh {
                await TeamPresenceMonitor.sweep(storage: presenceStorage)
            }
            refreshDeliveryLiveness(records: records)
            let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
            await Self.retryNativeDeliveryForPresenceWorktrees(
                inbox: services.teamInbox,
                records: records,
                deliveries: Self.nativeDeliveries(
                    codex: codexAppServerDeliveryService,
                    claude: claudePeerDeliveryService,
                    enabled: teamsEnabled
                )
            )
        }

        // Subscribe Codex app-server delivery to inbox file-system events.
        // TeamInboxObserver fires with the full message list on every
        // append. We track the previous count and fire onMessageArrival
        // only when new messages arrive, to avoid redundant delivers.
        // We watch each team's inbox for all repos that exist at startup time;
        // the watcher self-heals for the file-not-yet-created case via the
        // directory watch inside TeamInboxObserver.
        let inboxRoot = AppState.defaultDirectory
            .appendingPathComponent("team-inbox", isDirectory: true)
        for repo in binding.wrappedValue.repos {
            let teamID = repo.path
            let observer = TeamInboxObserver(rootDirectory: inboxRoot, teamID: teamID)
            // Per-observer state claims message ranges before awaiting
            // app-server delivery. `TeamInboxObserver` callbacks can overlap
            // once they hop through Task/MainActor, so the actor owns the
            // count update.
            // (A previous version used a shared `[String: Int]` map across
            // all observer closures and crashed under concurrent mutation
            // by multiple observer queues — Swift Dictionary is not
            // thread-safe.)
            let deliveryState = CodexAppServerInboxObserverDeliveryState(skipInitialSnapshot: true)
            let cancellable = observer.start {
                [weak codexAppServerDeliveryService, weak claudePeerDeliveryService] messages in
                Task { @MainActor in
                    refreshDeliveryLiveness()
                    guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else {
                        await deliveryState.markSeen(messages)
                        return
                    }
                    guard codexAppServerDeliveryService != nil || claudePeerDeliveryService != nil else {
                        await deliveryState.markSeen(messages)
                        return
                    }
                    let recipientWorktrees = await deliveryState.claimRecipientWorktrees(in: messages)
                    let awakeRecipients = recipientWorktrees.filter { tm.wakeWorktree($0) }
                    var deliveries: [any CodexAppServerDeliveryTrigger] = []
                    if let codexAppServerDeliveryService {
                        deliveries.append(codexAppServerDeliveryService)
                    }
                    if let claudePeerDeliveryService {
                        deliveries.append(claudePeerDeliveryService)
                    }
                    await Self.drainNativeDeliveryMessages(
                        teamID: teamID,
                        recipientWorktrees: awakeRecipients,
                        inbox: services.teamInbox,
                        deliveries: deliveries
                    )
                }
            }
            services.inboxObserverCancellables.append(cancellable)
            services.inboxObservers.append(observer)
        }

        // Persist the delivery service on AppServices so it outlives startup().
        services.codexAppServerDeliveryService = codexAppServerDeliveryService
        services.claudePeerDeliveryService = claudePeerDeliveryService

        // When a pane is destroyed, sweep any TeamPresenceRecord whose
        // paneSessionName matches the closing pane. The agent's own
        // `team unregister` cleanup hook is the primary path; this fallback
        // covers the SIGKILL / hard-quit case where the pane went away
        // without the registered process getting a chance to clean up.
        tm.paneClosed = { [presenceStorage] _, sessionName in
            guard let sessionName else { return }
            services.claudeSessionRegistry.removePane(sessionName)
            _ = refreshPresenceIndex()
            for record in presenceIndex.records(forPaneSessionName: sessionName) {
                try? presenceStorage.delete(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName,
                    agentID: record.agentID
                )
                presenceIndex.remove(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName
                )
            }
            let records = presenceIndex.allRecords()
            refreshDeliveryLiveness(records: records)
            Task {
                await Self.retryNativeDeliveryForPresenceWorktrees(
                    inbox: services.teamInbox,
                    records: records,
                    deliveries: Self.nativeDeliveries(
                        codex: codexAppServerDeliveryService,
                        claude: claudePeerDeliveryService,
                        enabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
                    )
                )
            }
        }

        tm.restorePaneTitleMetadata(appState.savedPaneTitleMetadata)
        restoreRunningWorktrees()

        // Restoring running worktrees installs the durable pane-to-session
        // mappings used by automatic delivery liveness. Refresh only after
        // those mappings exist, then retry unread rows from while the app was
        // down; otherwise a background owner can be skipped until the
        // 30-second presence ticker runs.
        func refreshAndRetryRestoredDelivery() {
            let restoredPresenceRecords = refreshPresenceIndex()
            refreshDeliveryLiveness(records: restoredPresenceRecords)
            Task {
                await Self.retryNativeDeliveryForPresenceWorktrees(
                    inbox: services.teamInbox,
                    records: restoredPresenceRecords,
                    deliveries: Self.nativeDeliveries(
                        codex: codexAppServerDeliveryService,
                        claude: claudePeerDeliveryService,
                        enabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
                    )
                )
            }
        }
        refreshAndRetryRestoredDelivery()

        reconcileOnLaunch {
            staleWorktreeAutoDismissTicker.start {
                _ = await StaleWorktreeDismissal.dismissExpired(
                    appState: binding,
                    now: Date(),
                    discoverWorktrees: { repo in
                        if !repo.isGitTracked,
                           !FileManager.default.fileExists(atPath: repo.path) {
                            return []
                        }
                        return try await WorktreeDiscovery.discover(repo: repo)
                    },
                    destroySurfaces: {
                        tm.destroySurfaces(terminalIDs: $0)
                    },
                    clearPRStatus: {
                        autoDismissPRStatusStore.clear(worktreePath: $0)
                    },
                    clearStats: {
                        autoDismissStatsStore.clear(worktreePath: $0)
                    },
                    onDismiss: {
                        Self.persistAppState($0)
                    }
                )
            }
            refreshAndRetryRestoredDelivery()
        }

        // TERM-11.5: WebSocket `/ws` sessions report attach/detach into the
        // shared registry so Mac pane backends can see web-client attaches.
        webController.setRemoteAttachmentRegistry(services.remoteAttachmentRegistry)

        webController.setGhosttyKeybindingsProvider { [tm = terminalManager] in
            await MainActor.run { tm.keybindBridge.allChords }
        }

        // WEB-5.4: feed the web server a snapshot of running sessions on
        // each GET /sessions request. Binding snapshot is read on the
        // main actor; worktree names are routed through
        // `SidebarWorktreeLabel.text` so the iOS session picker matches
        // every other sidebar-adjacent surface — most notably, the main
        // checkout renders as the resolved default branch, not the
        // directory basename.
        let appStateBinding = $appState
        let panesRemoteBranchStore = services.remoteBranchStore
        webController.setSessionsProvider {
            await MainActor.run { () -> [SessionInfo] in
                var sessions: [SessionInfo] = []
                for repo in appStateBinding.wrappedValue.repos {
                    let siblingPaths = repo.worktrees.map(\.path)
                    let defaultBranch = panesRemoteBranchStore.resolvedDefaultBranch(
                        forRepoAt: repo.path,
                        hint: repo.defaultBranchHint
                    )
                    for wt in repo.worktrees where wt.state == .running {
                        let worktreeDisplayName = SidebarWorktreeLabel.text(
                            for: wt,
                            inRepoAtPath: repo.path,
                            siblingPaths: siblingPaths,
                            defaultBranch: defaultBranch
                        )
                        for leafID in wt.splitTree.allLeaves {
                            guard let sessionID = wt.paneSessions[leafID] else { continue }
                            let sessionName = ZmxLauncher.sessionName(for: sessionID)
                            sessions.append(SessionInfo(
                                name: sessionName,
                                worktreePath: wt.path,
                                repoDisplayName: repo.displayName,
                                worktreeDisplayName: worktreeDisplayName
                            ))
                        }
                    }
                }
                return sessions
            }
        }

        // Web/iOS attaches spawn their own `zmx attach` process. If that
        // attach wins the race to create a new zmx daemon, its cwd becomes
        // the daemon's shell cwd, so resolve the pane back to its worktree.
        webController.setSessionSpawnProvider { [terminalManager = tm] sessionName in
            await MainActor.run {
                terminalManager.remoteSpawnConfiguration(forSessionName: sessionName)
            }
        }
        webController.setSessionWorktreeProvider { sessionName in
            await MainActor.run { () -> String? in
                for repo in appStateBinding.wrappedValue.repos {
                    for wt in repo.worktrees where wt.state == .running {
                        for leafID in wt.splitTree.allLeaves
                        where wt.paneSessions[leafID].map(ZmxLauncher.sessionName(for:)) == sessionName {
                            return wt.path
                        }
                    }
                }
                return nil
            }
        }

        // IOS-4.10: per-worktree pane trees + titles for the mobile
        // client's sidebar mirror. Includes non-running worktrees so
        // closed/stale/creating rows render their state via icon +
        // color, same as on macOS.
        //
        // Hoisted out of `setWorktreePanesProvider` so the R5 SSH
        // `panes-state@graftty.dev` channel can re-use the same snapshot
        // shape. The two consumers (`/worktrees/panes` HTTP poll and
        // `panes-state` SSH channel) MUST produce identical envelopes
        // so the iPad's sidebar renders the same regardless of transport.
        let terminalManager = tm
        let panesPortBindings = portBindingsModel
        let panesStatsStore = services.statsStore
        let panesPRStore = services.prStatusStore
        let panesPortScanner = portScanner
        let panesClaudeRegistry = services.claudeSessionRegistry
        let localWorktreeOrigin = WorktreeOrigin(
            deviceID: AppServices.localRemoteDeviceID(),
            deviceLabel: AppServices.localHostDisplayName(),
            relayDepth: 0
        )
        let buildWorktreePanesSnapshot: @Sendable @MainActor () -> [WorktreePanes] = {
            var out: [WorktreePanes] = []
            for repo in appStateBinding.wrappedValue.repos {
                let projectID = "\(localWorktreeOrigin.deviceID.value):\(repo.id.uuidString)"
                let ancestry = SidebarHostNavigation.folderAncestry(in: repo)
                let defaultBranch = panesRemoteBranchStore.resolvedDefaultBranch(
                    forRepoAt: repo.path,
                    hint: repo.defaultBranchHint
                )
                let labels = SidebarWorktreeLabel.texts(
                    for: repo.worktrees,
                    inRepoAtPath: repo.path,
                    defaultBranch: defaultBranch
                )
                for wt in SidebarHostNavigation.displayedWorktrees(in: repo) {
                    let stats = wt.state.hasOnDiskWorktree
                        ? panesStatsStore.stats[wt.path]
                        : nil
                    out.append(WorktreePanes(
                        path: wt.path,
                        displayName: labels[wt.id] ?? "",
                        repoDisplayName: repo.displayName,
                        repositoryID: repo.path,
                        displayBranch: wt.displayBranch,
                        state: WorktreeWireState(wt.state),
                        isMainCheckout: wt.path == repo.path,
                        prBadge: panesPRStore.infos[wt.path].map(PRBadge.init(from:)),
                        stats: stats?.toWire(),
                        attentionText: wt.attention?.text,
                        attentionSource: wt.attention?.source,
                        attentionTimestamp: wt.attention?.timestamp,
                        layout: (wt.state == .running ? wt.splitTree.root : nil)
                            .map {
                                paneLayoutNode(
                                    from: $0,
                                    paneSessions: wt.paneSessions,
                                    titles: terminalManager.displayTitles,
                                    paneAttention: wt.paneAttention,
                                    liveness: panesClaudeRegistry.livenessBySession
                                )
                            },
                        origin: localWorktreeOrigin,
                        sidebar: SidebarHostNavigation.metadata(for: wt, projectID: projectID,
                            folders: ancestry[wt.id]?.map(\.name) ?? [], repositoryPath: repo.path, folderIDs: ancestry[wt.id]?.map(\.id)),
                        ports: wt.state == .running ? panesPortBindings.ports(for: wt.splitTree.allLeaves) : [],
                        portBindings: wt.state == .running ? Dictionary(uniqueKeysWithValues: wt.splitTree.allLeaves.compactMap { slot in
                            guard let session = wt.paneSessions[slot], let bindings = panesPortBindings.bindings[slot], !bindings.isEmpty else { return nil }
                            return (ZmxLauncher.sessionName(for: session), bindings)
                        }) : nil
                    ))
                }
            }
            return out
        }
        webController.setWorktreePanesProvider {
            await MainActor.run { buildWorktreePanesSnapshot() }
        }
        webController.setRelayedWorktreePanesProvider {
            await services.remoteMacsModel.promotedWorktreesForRelay()
        }

        let statsStore = services.statsStore

        // WEB-7.1: feed the web server the repo list for the "Add
        // Worktree" picker. Mirrors the native sidebar's top-level
        // repos.
        webController.setReposProvider {
            await MainActor.run { () -> [WebServer.RepoInfo] in
                appStateBinding.wrappedValue.repos.map { repo in
                    WebServer.RepoInfo(
                        path: repo.path,
                        displayName: repo.displayName,
                        defaultBranchStatus: defaultBranchStatus(
                            for: repo,
                            stats: statsStore.stats[repo.path]
                        ),
                        origin: localWorktreeOrigin
                    )
                }
            }
        }
        webController.setRelayedReposProvider {
            await services.remoteMacsModel
                .promotedRepositoriesForRelay()
                .map { repository in
                    WebServer.RepoInfo(
                        path: repository.id,
                        displayName: repository.displayName,
                        defaultBranchStatus: repository.defaultBranchStatus.map {
                            .init(
                                branchName: $0.branchName,
                                remoteRef: $0.remoteRef,
                                behindCount: $0.behindCount
                            )
                        },
                        branches: repository.branches,
                        origin: repository.origin
                    )
                }
        }

        // WEB-7.2: drive `POST /worktrees` into the shared
        // `AddWorktreeFlow`. `AddWorktreeFlow.add` is itself
        // `@MainActor`; calling it from this non-isolated async closure
        // inserts an implicit hop, so every write to appState and every
        // terminal-surface creation happens on the main actor — same
        // isolation as the native sidebar's "+" button.
        let worktreeMonitor = services.worktreeMonitor
        let dispatcherForWeb = services.teamEventDispatcher
        webController.setDefaultBranchPuller { req in
            let pullTarget = await MainActor.run {
                guard let repo = appStateBinding.wrappedValue.repos.first(where: { $0.path == req.repoPath }) else {
                    return (tracked: false, status: nil as WebServer.RepoInfo.DefaultBranchStatus?)
                }
                return (tracked: true, status: defaultBranchStatus(
                    for: repo,
                    stats: statsStore.stats[repo.path]
                ))
            }
            guard pullTarget.tracked else {
                return .invalid("repository not tracked")
            }
            guard let status = pullTarget.status else {
                return .invalid("default checkout is not behind origin")
            }
            do {
                try await GitDefaultBranchPull.pull(repoPath: req.repoPath, branchName: status.branchName)
            } catch GitDefaultBranchPull.Error.gitFailed(_, let stderr) {
                return .gitFailed(stderr)
            } catch {
                return .internalFailure("\(error)")
            }
            await MainActor.run {
                guard let repo = appStateBinding.wrappedValue.repos.first(where: { $0.path == req.repoPath }) else {
                    return
                }
                let branch = repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
                statsStore.refresh(worktreePath: repo.path, repoPath: repo.path, branch: branch)
            }
            return .success(WebServer.PullDefaultBranchResponse(ok: true))
        }
        webController.setWorktreeCreator { req in
            let branch: BranchSelection
            if req.existing {
                branch = .useExisting(name: req.branchName, source: .local)
            } else {
                branch = .createNew(name: req.branchName)
            }
            let result = await AddWorktreeFlow.add(
                repoPath: req.repoPath,
                worktreeName: req.worktreeName,
                branch: branch,
                appState: appStateBinding,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                terminalManager: tm,
                teamEventDispatcher: dispatcherForWeb
            )
            switch result {
            case .success(let outcome):
                return .success(WebServer.CreateWorktreeResponse(
                    sessionName: outcome.sessionName,
                    worktreePath: outcome.worktreePath
                ))
            case .failure(let err):
                switch err {
                case .gitFailed(let msg): return .gitFailed(msg)
                case .repoNotFound: return .invalid("repository not tracked")
                case .pathCollision: return .invalid("a worktree at that name already exists")
                case .branchAlreadyMounted:
                    return .conflict(message: err.userMessage ?? "branch already mounted")
                case .invalidInput(let msg): return .invalid(msg)
                case .discoveryFailed(let msg): return .internalFailure(msg)
                }
            }
        }

        // WEB-7.8: drive `POST /worktrees/delete` into the shared
        // `DeleteWorktreeFlow`. Mirrors the create wiring above —
        // closure runs on `MainActor` via `DeleteWorktreeFlow.delete`'s
        // `@MainActor` isolation, so every `appState` mutation and
        // surface teardown lands on the main actor, same as the native
        // sidebar's "Delete Worktree" path.
        webController.setWorktreeRemover { req in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: req.worktreePath,
                force: req.force,
                appState: appStateBinding,
                terminalManager: tm,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: dispatcherForWeb
            )
            switch result {
            case .success(let outcome):
                return .success(WebServer.DeleteWorktreeResponse(dismissed: outcome.dismissed))
            case .failure(.notFound):
                return .notFound("unknown worktree path")
            case .failure(.mainCheckoutRejected):
                return .invalid("cannot delete the repo's main checkout")
            case .failure(.gitFailedForceable(let stderr, let status)):
                return .gitFailedForceable(stderr: stderr, shortStatus: status)
            case .failure(.gitFailedFinal(let msg)):
                return .gitFailedFinal(msg)
            }
        }

        // Prepare production channel callbacks before creating the pool and
        // starting the paired-access listener.
        //
        // `panesStateSubscribe`: emits initial snapshot, then polls
        // `buildWorktreePanesSnapshot` on a 1Hz cadence and re-emits when
        // the snapshot differs from the previously-sent one. Polling
        // (rather than a pub-sub source) is intentional — AppState is a
        // SwiftUI `@State` value type with no Combine/AsyncStream publisher,
        // and the `/ws` HTTP path the desktop sidebar/web client uses is
        // itself poll-based, so the SSH transport doesn't promise tighter
        // freshness than the HTTP transport already provides. A pub-sub
        // hook is left as a post-R6 follow-up.
        //
        // `paneControlMutator`: maps session-name targets to `PaneSlotID`
        // via `TerminalManager.paneID(forSessionName:)` and dispatches to
        // the same `splitPane` / `closePane` static methods the Mac sidebar
        // context menu drives. `swap` returns `unsupported` — no native
        // implementation exists yet; tracked as a post-R5 follow-up.
        services.hostPairingCoordinator.setStartupError(
            "Paired access is still starting. Try again in a moment."
        )
        if let hostKey {
            let panesStateSubscribe: PanesStateChannelHandler.Subscribe = { onChange in
                // Initial snapshot fires synchronously so the first frame
                // hits the wire before the polling loop's first sleep.
                let snapshot: @MainActor () -> PanesStateMessage = {
                    let projects = SidebarHostController.shared.localProjects(appStateBinding.wrappedValue.repos, owner: localWorktreeOrigin)
                    let navigation = SidebarSnapshot(projects: (appStateBinding.wrappedValue.sidebarNavigation?.order ?? .init()).sorted(projects))
                    return .snapshot(buildWorktreePanesSnapshot(), sidebar: navigation)
                }
                let initial = await MainActor.run { snapshot() }
                await onChange(initial)

                let task = Task {
                    var last = initial
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        let next = await MainActor.run { snapshot() }
                        if next != last {
                            last = next
                            await onChange(next)
                        }
                    }
                }
                return PanesStateChannelHandler.Cancellable {
                    task.cancel()
                }
            }

            let panesStateV2Subscribe: PanesStateChannelHandler.Subscribe = {
                onChange in
                let snapshot: @MainActor () async -> PanesStateMessage = {
                    let remote = await services.remoteMacsModel.sidebarRelaySnapshot()
                    let navigation = SidebarHostController.shared.snapshot(state: appStateBinding, owner: localWorktreeOrigin, remote: remote.projects,
                        authoritativeRemoteOwners: remote.authoritativeOwnerIDs, savedRemoteOwners: Set(services.remoteMacsModel.savedRemoteMacs.map(\.id)))
                    let worktrees = buildWorktreePanesSnapshot() + remote.worktrees
                    let order = Dictionary(navigation.projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
                    let sorted = worktrees.enumerated().sorted {
                        let a = order[SidebarProjection.projectID($0.element), default: .max]
                        let b = order[SidebarProjection.projectID($1.element), default: .max]
                        return a == b ? $0.offset < $1.offset : a < b
                    }.map(\.element)
                    return .snapshot(sorted, sidebar: navigation)
                }
                let initial = await snapshot()
                await onChange(initial)

                let task = Task {
                    var last = initial
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        let next = await snapshot()
                        if next != last {
                            last = next
                            await onChange(next)
                        }
                    }
                }
                return PanesStateChannelHandler.Cancellable {
                    task.cancel()
                }
            }

            let paneControlMutator: PaneControlChannelHandler.Mutator = Self.makePaneControlMutator(
                appState: appStateBinding,
                terminalManager: terminalManager,
                services: services
            )
            let worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator =
                Self.makeWorktreeManagementMutator(
                    appState: appStateBinding,
                    terminalManager: terminalManager,
                    services: services,
                    portScanner: panesPortScanner,
                    localWorktreeOrigin: localWorktreeOrigin
                )

            // Explicit phone launch opts into an isolated worktree profile.
            let chromeBroker = ChromeTabBroker(authorize: { target, peerID in
                await MainActor.run {
                    guard let peer = try? trustedPeerStore.get(id: RemoteDeviceID(value: peerID)),
                          peer.capabilities.terminalControl == .allowed,
                          peer.capabilities.worktreeManagement == .allowed,
                          terminalManager.paneID(forSessionName: target) != nil,
                          let path = terminalManager.worktreePath(forSessionName: target),
                          ChromeTabBroker.ownsDisplay(clientID: services.displayOwnershipStore.snapshot(sessionName: target).ownerClientID?.rawValue, peerID: peerID) else { return nil }
                    return path
                }
            }, makeBackend: { DedicatedChromeBackend(worktreePath: $0) })
            let chromeTabMutator: ChromeTabChannelHandler.Mutator = { request, peer, viewer in
                await chromeBroker.handle(request, peerID: peer.value, viewerID: viewer)
            }
            let chromeTabOnDisconnect: ChromeTabChannelHandler.OnDisconnect = { viewer in
                await chromeBroker.disconnect(viewerID: viewer)
            }

            // Every device gets a fully configured connection agent. Shared
            // registries keep revocation and routing consistent across devices.
            let activeRemotePeers = ActiveRemotePeerRegistry()
            let hostAgentPool = WebRTCHostAgentPool(makeAgent: {
                [hostKey, trustedPeerStore, sshConnectionRegistry,
                 terminalManager = terminalManager,
                 registry = services.remoteAttachmentRegistry,
                 remoteMacsModel = services.remoteMacsModel,
                 remoteTeamRouter = services.remoteTeamRouter,
                 displayOwnershipStore = services.displayOwnershipStore,
                 activeRemotePeers, panesStateSubscribe, panesStateV2Subscribe,
                 paneControlMutator, worktreeManagementMutator, chromeTabMutator, chromeTabOnDisconnect,
                 zmxExe = zmxBinary, zmxDir] in
                let hostAgent = WebRTCHostAgent(
                    hostKey: hostKey,
                    trustedPeerStore: trustedPeerStore,
                    activeRemotePeers: activeRemotePeers,
                    streamFactory: {
                        [registry, terminalManager, remoteMacsModel, zmxExe, zmxDir] sessionName in
                        if sessionName.hasPrefix("relay-pane-") {
                            return try await remoteMacsModel.openRelayedTerminal(
                                alias: sessionName
                            )
                        }
                        let (workingDirectoryPath, spawnConfiguration) = await MainActor.run {
                            (terminalManager.worktreePath(forSessionName: sessionName),
                             terminalManager.remoteSpawnConfiguration(forSessionName: sessionName))
                        }
                        let workingDirectory = workingDirectoryPath.map {
                            URL(fileURLWithPath: $0, isDirectory: true)
                        }
                        let engine = ZmxAttachEngine(config: ZmxAttachEngine.Config(
                            zmxExecutable: zmxExe,
                            zmxDir: zmxDir,
                            sessionName: sessionName,
                            workingDirectory: workingDirectory,
                            spawnConfiguration: spawnConfiguration
                        ))
                        engine.attachmentRegistry = registry
                        try engine.start()
                        return engine
                    },
                    pagedFactory: { [registry, terminalManager, remoteMacsModel, zmxExe, zmxDir] sessionName in
                        if sessionName.hasPrefix("relay-pane-") {
                            return try await remoteMacsModel.openRelayedPagedTerminal(alias: sessionName)
                        }
                        let (path, spawnConfiguration) = await MainActor.run {
                            (terminalManager.worktreePath(forSessionName: sessionName),
                             terminalManager.remoteSpawnConfiguration(forSessionName: sessionName))
                        }
                        // Paging attaches only to existing daemons. A newly
                        // created mobile pane must first spawn its shell.
                        var bootstrap: ZmxAttachEngine?
                        defer { bootstrap?.close() }
                        let socket = zmxDir.appendingPathComponent(sessionName).path
                        if !FileManager.default.fileExists(atPath: socket) {
                            let session = ZmxAttachEngine(config: .init(
                                zmxExecutable: zmxExe, zmxDir: zmxDir, sessionName: sessionName,
                                workingDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                spawnConfiguration: spawnConfiguration
                            ))
                            // Discard bootstrap output. The paged channel will
                            // obtain its own checkpoint once the daemon exists.
                            session.onPTYData = { _ in }
                            bootstrap = session
                            try session.start()
                            let deadline = ContinuousClock.now + .seconds(5)
                            while !FileManager.default.fileExists(atPath: socket), ContinuousClock.now < deadline {
                                try await Task.sleep(for: .milliseconds(20))
                            }
                        }
                        let engine = PagedZmxAttachEngine(config: .init(
                            zmxExecutable: zmxExe, zmxDir: zmxDir, sessionName: sessionName,
                            workingDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ))
                        engine.attachmentRegistry = registry
                        try await engine.start()
                        return engine
                    },
                    panesStateSubscribe: panesStateSubscribe,
                    panesStateV2Subscribe: panesStateV2Subscribe,
                    paneControlMutator: paneControlMutator,
                    worktreeManagementMutator: worktreeManagementMutator,
                    chromeTabMutator: chromeTabMutator, chromeTabOnDisconnect: chromeTabOnDisconnect,
                    displayOwnershipStore: displayOwnershipStore,
                    sshConnectionRegistry: sshConnectionRegistry
                )
                await hostAgent.setTeamMessaging(
                    handler: { deviceID, data in
                        await remoteTeamRouter.receive(from: deviceID, data: data)
                    },
                    onConnect: { deviceID, session in
                        let label = (try? trustedPeerStore.get(id: deviceID))?.displayName ?? deviceID.value
                        await remoteTeamRouter.register(
                            deviceID: deviceID,
                            connectionID: session.id,
                            label: label,
                            closeForReconnect: { await session.close() }
                        ) { data in try await session.send(data) }
                    },
                    onDisconnect: { deviceID, connectionID in
                        await remoteTeamRouter.unregister(deviceID: deviceID, connectionID: connectionID)
                    }
                )
                return hostAgent
            })
            services.hostAgentPool = hostAgentPool
            Task { @MainActor in
                do {
                    try await services.startRemoteMacAccessServices(
                        hostAgentPool: hostAgentPool
                    )
                    services.hostPairingCoordinator.setStartupError(nil)
                } catch {
                    services.hostPairingCoordinator.setStartupError(
                        Self.remoteAccessStartupMessage(for: error)
                    )
                    NSLog(
                        "[Graftty] failed to start LAN remote access services: %@",
                        String(describing: error)
                    )
                }
            }
        } else {
            Task { @MainActor in
                do {
                    try await services.startRemoteMacAccessServices(
                        hostAgentPool: nil
                    )
                    services.hostPairingCoordinator.setStartupError(nil)
                } catch {
                    services.hostPairingCoordinator.setStartupError(
                        Self.remoteAccessStartupMessage(for: error)
                    )
                    NSLog(
                        "[Graftty] failed to start LAN remote access services: %@",
                        String(describing: error)
                    )
                }
            }
        }

        // WEB-4.3: close the NIO listen sockets + SIGTERM any in-flight
        // `zmx attach` children as part of normal shutdown. Process exit
        // would eventually do both, but we can't rely on that: WEB-4.6's
        // FD_CLOEXEC sweep inside PtyProcess is a defense-in-depth safety
        // net, not the primary teardown path. Running stop() explicitly
        // means the 500ms SIGTERM→waitpid window in WebSession.close()
        // gets a chance to reap cleanly before NSApplication pulls the
        // rug out.
        let controller = webController
        let appServices = services
        let stateBinding = binding
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // PERSIST-2.1: save process-lifetime mutations even when the
                // main window (and its `.onChange` observer) is closed.
                stateBinding.wrappedValue.capturePaneTitleMetadata(tm.paneTitleMetadata)
                tm.autoSleep.shutdown()
                Self.persistAppState(stateBinding.wrappedValue)
                appServices.stopRemoteMacAccessServices()
                appServices.remoteBranchStore.stop()
                appServices.prStatusStore.stop()
                appServices.statsStore.stop()
                controller.stop()
            }
        }
    }

    private static func remoteAccessStartupMessage(for error: Error) -> String {
        if let serviceError = error as? AppServices.RemoteMacAccessServiceError {
            switch serviceError {
            case .disabled:
                return "Paired-device access is disabled in this Graftty configuration."
            case .hostAgentUnavailable:
                return "Paired-device access is unavailable because WebRTC could not start."
            case .listenerPortUnavailable:
                break
            }
        }
        return """
        Paired-device access could not start on port \
        \(AppServices.pairedAccessPort). Quit the other process using \
        that port, then restart Graftty. (\(error))
        """
    }
}

/// Convert the Mac-side `SplitTree.Node` into the wire-format
/// `PaneLayoutNode`. Leaves carry the ZMX session name, the pane's
/// current displayed title (or the empty string if no metadata has arrived
/// yet), and the pane-scoped attention text from the worktree's
/// `paneAttention`.
@MainActor
func paneLayoutNode(
    from node: SplitTree.Node,
    paneSessions: [PaneSlotID: PaneSessionID],
    titles: [PaneSlotID: String],
    paneAttention: [PaneSlotID: Attention],
    liveness: [String: AgentLiveness]
) -> PaneLayoutNode {
    switch node {
    case .leaf(let id):
        let sessionName = paneSessions[id].map(ZmxLauncher.sessionName(for:))
        return .leaf(
            sessionName: sessionName ?? "",
            title: titles[id] ?? "",
            attentionText: paneAttention[id]?.text,
            isBusy: AgentLivenessMerge.isPaneBusy(
                sessionName: sessionName,
                liveness: liveness),
            attentionSource: paneAttention[id]?.source,
            attentionTimestamp: paneAttention[id]?.timestamp
        )
    case .split(let s):
        return .split(
            direction: s.direction == .horizontal ? .horizontal : .vertical,
            ratio: s.ratio,
            left: paneLayoutNode(
                from: s.left,
                paneSessions: paneSessions,
                titles: titles,
                paneAttention: paneAttention,
                liveness: liveness
            ),
            right: paneLayoutNode(
                from: s.right,
                paneSessions: paneSessions,
                titles: titles,
                paneAttention: paneAttention,
                liveness: liveness
            )
        )
    }
}

extension WorktreeWireState {
    /// Exhaustive bridge from the persistence-side `WorktreeState` (in
    /// GrafttyKit, whose `encode(to:)` coerces `.creating` and
    /// `.deleting` to `.closed`) to the wire enum. A `switch` rather
    /// than `rawValue` round-trip so a future `WorktreeState` case is a
    /// compile error here.
    init(_ state: WorktreeState) {
        switch state {
        case .closed: self = .closed
        case .running: self = .running
        case .stale: self = .stale
        case .creating: self = .creating
        case .deleting: self = .deleting
        }
    }
}

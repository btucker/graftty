import SwiftUI
import AppKit
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
        UserDefaults.standard.register(defaults: DefaultPrompts.registrations)

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

        // Web access server. It uses the same `ZmxPaths` as `startup()` so its
        // child `zmx attach` invocations hit the same ZMX_DIR as panes spawned
        // from the app UI. Building it here (rather than in AppServices) keeps
        // the controller's lifetime tied to the SwiftUI App via @StateObject,
        // which is what Settings scene re-entry expects.
        let webController = WebServerController(
            settings: WebAccessSettings.shared,
            zmxExecutable: ZmxPaths.executable,
            zmxDir: ZmxPaths.directory,
            displayOwnershipStore: appServices.displayOwnershipStore
        )
        _webController = StateObject(wrappedValue: webController)
        _updaterController = StateObject(wrappedValue: UpdaterController())
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
                appStateChanges: services.appStateChanges,
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
                // it's a Graftty-specific action with no Ghostty equivalent.
                AddRepositoryCommandButton()

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
            // window for the focused worktree's team. Disabled when no
            // tracked worktree is focused. The button is hosted inside a tiny View
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
                    trustedPeerStore: services.trustedPeerStore,
                    sshConnectionRegistry: services.sshConnectionRegistry
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
        let zmxBinary = ZmxPaths.executable
        let zmxDir = ZmxPaths.directory
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

        // PERF-1.18: every input folded into sidebar and panes-state
        // snapshots. AppState publishes on each persister mark, from
        // `.onChange(of: appState)` or a windowless mutator (PERF-1.22).
        let changes = services.appStateChanges
        changes.publish(onMarkDirtyOf: Self.appStatePersister)
        changes.publish(on: terminalManager.paneTitleInvalidations.$generation.dropFirst())
        changes.publish(on: portBindingsModel.objectWillChange)
        changes.publish(on: services.remoteMacsModel.objectWillChange)
        changes.publish(on: SidebarHostController.shared.objectWillChange)
        changes.publish(onChangeOf: { [services] in
            _ = services.prStatusStore.infos
            _ = services.statsStore.stats
            _ = services.claudeSessionRegistry.livenessBySession
            _ = services.remoteBranchStore.branchesByRepo
        })

        // 2s cadence for port-binding scans. Cheap (one batched lsof
        // across all registered shell PIDs per tick) and only meaningful
        // while the app is up, including while a mobile client is using it.
        portsTicker.start { [portScanner] in
            await portScanner.tick()
        }

        // Wrappers always go on PATH.
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

        TerminalPaneActions.install(
            on: terminalManager,
            appState: $appState,
            remoteBranchStore: services.remoteBranchStore,
            sessionRegistry: services.claudeSessionRegistry
        )

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
        let remoteTeamRouter = services.remoteTeamRouter
        let localWorktreeOrigin = WorktreeOrigin(
            deviceID: AppServices.localRemoteDeviceID(),
            deviceLabel: AppServices.localHostDisplayName(),
            relayDepth: 0
        )
        let worktreeManagement = WorktreeManagement(
            appState: binding, terminalManager: tm, services: services, localOrigin: localWorktreeOrigin
        )
        tm.agentCompletionLoader = { currentWorktreePath, update in
            let repos = binding.wrappedValue.repos
            async let remote = remoteTeamRouter.members()
            let local = await OffMainIO.run {
                AgentCompletionCatalog.local(repos: repos,
                    records: AppServices.presenceRecords(),
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
                    let response = await RemoteCLIWorktreeService.handle(
                        operation, from: deviceID, repos: binding.wrappedValue.repos,
                        platform: worktreeManagement)
                    return try JSONEncoder().encode(response)
                }
                let repos = binding.wrappedValue.repos
                let handler = RemoteTeamService(
                    inbox: teamInbox,
                    agentRecords: {
                        AppServices.presenceRecords()
                    },
                    agentReachability: { TeamAgentReachability.isReachable($0) }
                )
                let response = await OffMainIO.run {
                    handler.handle(request, from: deviceID, repos: repos)
                }
                return try JSONEncoder().encode(response)
            } catch {
                return (try? JSONEncoder().encode(RemoteTeamResponse.error("Invalid remote team request: \(error)"))) ?? Data()
            }
        }
        do {
            let socketRouter = SocketRequestRouter(
                appState: binding,
                terminalManager: tm,
                services: services
            )
            try SocketServerStartup.start(
                server: services.socketServer,
                onMessage: { message in
                    MainActor.assumeIsolated {
                        socketRouter.handleMessage(message)
                    }
                },
                onAsyncRequest: { message in
                    await socketRouter.handleRequest(message)
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
        let attentionDrain = AttentionHandoffDrain(
            handoff: attentionHandoff,
            apply: { activity in
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
            },
            // One off-main write per batch; files are deleted only after it
            // lands (REMOTE-23.10).
            persist: { try await Self.persistAppStateNow(binding.wrappedValue) }
        )
        do {
            try attentionObserver.start {
                Task { @MainActor in await attentionDrain.drain() }
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

        let nativeTeamDelivery = NativeTeamDelivery(
            services: services,
            terminalManager: tm,
            appState: binding
        )
        nativeTeamDelivery.install()

        tm.restorePaneTitleMetadata(appState.savedPaneTitleMetadata)
        restoreRunningWorktrees()

        // Restoring running worktrees installs the durable pane-to-session
        // mappings used by automatic delivery liveness. Refresh only after
        // those mappings exist, then retry unread rows from while the app was
        // down; otherwise a background owner can be skipped until the
        // 30-second presence ticker runs.
        nativeTeamDelivery.refreshAndRetryRestoredDelivery()

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
            nativeTeamDelivery.refreshAndRetryRestoredDelivery()
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
            await MainActor.run { worktreeManagement.worktreePath(forSessionName: sessionName) }
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
        let panesClaudeRegistry = services.claudeSessionRegistry
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
                    let running = wt.state == .running
                    out.append(WorktreePanes(entry: wt, repo: repo, inputs: WorktreeRowInputs(
                        origin: localWorktreeOrigin,
                        projectID: projectID,
                        displayName: labels[wt.id] ?? "",
                        folders: ancestry[wt.id],
                        prBadge: panesPRStore.infos[wt.path].map(PRBadge.init(from:)),
                        stats: panesStatsStore.stats[wt.path]?.toWire(),
                        paneTitles: terminalManager.displayTitles,
                        liveness: panesClaudeRegistry.livenessBySession,
                        ports: running ? panesPortBindings.ports(for: wt.splitTree.allLeaves) : [],
                        portBindings: running ? Dictionary(uniqueKeysWithValues: wt.splitTree.allLeaves.compactMap { slot in
                            guard let session = wt.paneSessions[slot], let bindings = panesPortBindings.bindings[slot], !bindings.isEmpty else { return nil }
                            return (ZmxLauncher.sessionName(for: session), bindings)
                        }) : nil
                    )))
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

        // WEB-7.1: feed the web server the repo list for the "Add
        // Worktree" picker. Mirrors the native sidebar's top-level
        // repos.
        webController.setReposProvider {
            await MainActor.run {
                worktreeManagement.repositories(includingBranches: false).map { WebServer.RepoInfo($0, includingBranches: false) }
            }
        }
        webController.setRelayedReposProvider {
            await services.remoteMacsModel
                .promotedRepositoriesForRelay()
                .map { WebServer.RepoInfo($0, includingBranches: true) }
        }
        webController.setDefaultBranchPuller { req in
            await .init(worktreeManagement.pullDefaultBranch(repoPath: req.repoPath))
        }

        // WEB-7.2: drive `POST /worktrees` into the shared
        // `AddWorktreeFlow` through `WorktreeManagement`, which is
        // `@MainActor`: every write to appState and every terminal-surface
        // creation happens on the main actor, as from the sidebar's "+".
        webController.setWorktreeCreator { req in
            let branch: BranchSelection = req.existing
                ? .useExisting(name: req.branchName, source: .local)
                : .createNew(name: req.branchName)
            return await .init(worktreeManagement.create(
                repoPath: req.repoPath, worktreeName: req.worktreeName, branch: branch, entryPoint: .web
            ))
        }

        // WEB-7.8: drive `POST /worktrees/delete` into the shared
        // `DeleteWorktreeFlow` through `WorktreeManagement`.
        webController.setWorktreeRemover { req in
            await .init(worktreeManagement.delete(worktreePath: req.worktreePath, force: req.force))
        }

        // Build the paired-device pool before starting the paired-access
        // listener.
        services.hostPairingCoordinator.setStartupError(
            "Paired access is still starting. Try again in a moment."
        )
        let hostAgentPool = services.hostKey().map { hostKey in
            Self.makeHostAgentPool(
                hostKey: hostKey,
                appState: appStateBinding,
                terminalManager: terminalManager,
                services: services,
                worktreeManagement: worktreeManagement,
                buildWorktreePanesSnapshot: buildWorktreePanesSnapshot,
                localWorktreeOrigin: localWorktreeOrigin,
                portScanner: portScanner,
                zmxBinary: zmxBinary,
                zmxDir: zmxDir
            )
        }
        services.hostAgentPool = hostAgentPool
        do { try services.parentMCPConnections.restore() }
        catch { NSLog("[Graftty] saved parent MCP connections could not be restored") }
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
                try? Self.persistAppStateSynchronously(stateBinding.wrappedValue)
                appServices.parentMCPConnections.cancel()
                appServices.parentMCPProcesses.close()
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


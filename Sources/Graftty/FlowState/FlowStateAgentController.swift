import Foundation
import GrafttyKit

enum FlowStateRuntime: String, Equatable, CaseIterable {
    case codex
    case claude

    init(settingsValue: String) {
        self = FlowStateRuntime(rawValue: settingsValue) ?? .codex
    }
}

struct FlowStateRuntimeCapabilities: Equatable {
    var codexSupportsSystemPromptConfig: Bool
    var claudeSupportsSystemPromptFile: Bool
}

enum FlowStateRuntimeLaunchCommand {
    static func build(
        runtime: FlowStateRuntime,
        workspaceURL: URL,
        promptFileURL: URL,
        systemPrompt: String,
        socketPath: String,
        capabilities: FlowStateRuntimeCapabilities = .init(
            codexSupportsSystemPromptConfig: false,
            claudeSupportsSystemPromptFile: true
        )
    ) -> String {
        let workspace = shellQuote(workspaceURL.path)
        let socket = shellQuote(socketPath)
        let envPrefix = "GRAFTTY_SOCK=\(socket)"

        switch runtime {
        case .codex:
            var parts = ["codex", "--cd", workspace]
            if !capabilities.codexSupportsSystemPromptConfig {
                parts.append(shellQuote(systemPrompt))
            }
            return "\(envPrefix) \(parts.joined(separator: " "))"

        case .claude:
            var parts = ["claude"]
            if capabilities.claudeSupportsSystemPromptFile {
                parts.append("--system-prompt-file")
                parts.append(shellQuote(promptFileURL.path))
            }
            parts.append("--permission-mode")
            parts.append("manual")
            parts.append("--name")
            parts.append(shellQuote("Flow State"))
            return "cd \(workspace) && \(envPrefix) \(parts.joined(separator: " "))"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

struct FlowStateAgentSettings: Equatable {
    var enabled: Bool
    var runtime: FlowStateRuntime
    var systemPrompt: String
    var permissionMode: String

    static func current(userDefaults: UserDefaults = .standard) -> FlowStateAgentSettings {
        FlowStateAgentSettings(
            enabled: userDefaults.bool(forKey: SettingsKeys.flowStateEnabled),
            runtime: FlowStateRuntime(
                settingsValue: userDefaults.string(forKey: SettingsKeys.flowStateRuntime) ?? "codex"
            ),
            systemPrompt: userDefaults.string(forKey: SettingsKeys.flowStateSystemPrompt)
                ?? FlowStateDefaults.systemPrompt,
            permissionMode: userDefaults.string(forKey: SettingsKeys.flowStatePermissionMode)
                ?? FlowStatePermissionMode.conservative.rawValue
        )
    }
}

@MainActor
protocol FlowStateAgentLaunching: AnyObject {
    func createSurface(
        terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        extraInitialInput: String
    ) -> Bool
    func destroySurfaces(terminalIDs: [PaneSlotID])
    func typeText(_ text: String, into terminalID: PaneSlotID, claimEngagement: Bool)
}

@MainActor
final class TerminalFlowStateAgentLauncher: FlowStateAgentLaunching {
    private weak var terminalManager: TerminalManager?

    init(terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
    }

    func createSurface(
        terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        extraInitialInput: String
    ) -> Bool {
        terminalManager?.createSurface(
            terminalID: terminalID,
            paneSessionID: paneSessionID,
            worktreePath: worktreePath,
            extraInitialInput: extraInitialInput
        ) != nil
    }

    func destroySurfaces(terminalIDs: [PaneSlotID]) {
        terminalManager?.destroySurfaces(terminalIDs: terminalIDs)
    }

    func typeText(_ text: String, into terminalID: PaneSlotID, claimEngagement: Bool) {
        terminalManager?.handle(for: terminalID)?.typeText(text, claimEngagement: claimEngagement)
    }
}

@MainActor
final class FlowStateNoopAgentLauncher: FlowStateAgentLaunching {
    func createSurface(
        terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        extraInitialInput: String
    ) -> Bool {
        true
    }

    func destroySurfaces(terminalIDs: [PaneSlotID]) {}

    func typeText(_ text: String, into terminalID: PaneSlotID, claimEngagement: Bool) {}
}

@MainActor
final class FlowStateAgentController: ObservableObject {
    @Published var splitTree: SplitTree = SplitTree(root: nil)
    @Published var paneSessions: [PaneSlotID: PaneSessionID] = [:]
    @Published var focusedPaneSlotID: PaneSlotID?
    @Published private(set) var status: FlowStatus
    @Published private(set) var pendingRestartReason: String?

    let workspaceURL: URL
    let promptFileURL: URL

    private let launcher: any FlowStateAgentLaunching
    private let socketPath: String
    private var settings: FlowStateAgentSettings
    private var liveTerminalID: PaneSlotID?
    private var livePaneSessionID: PaneSessionID?
    private var launchedSettings: FlowStateAgentSettings?

    init(
        launcher: any FlowStateAgentLaunching,
        defaultDirectory: URL = AppState.defaultDirectory,
        socketPath: String,
        settings: FlowStateAgentSettings = .current()
    ) {
        self.launcher = launcher
        self.socketPath = socketPath
        self.settings = settings
        self.workspaceURL = defaultDirectory
            .appendingPathComponent("flow-state", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        self.promptFileURL = defaultDirectory
            .appendingPathComponent("flow-state", isDirectory: true)
            .appendingPathComponent("system-prompt.md")
        self.status = Self.makeStatus(settings: settings, running: false, pendingRestartReason: nil)
    }

    func ensureRunning() throws {
        try ensureRunning(settings: settings)
    }

    func ensureRunning(settings newSettings: FlowStateAgentSettings) throws {
        settings = newSettings
        guard settings.enabled else {
            updateStatus()
            return
        }
        guard liveTerminalID == nil else {
            updateStatus()
            return
        }

        try prepareWorkspace()

        let terminalID = PaneSlotID()
        let paneSessionID = PaneSessionID()
        let command = FlowStateRuntimeLaunchCommand.build(
            runtime: settings.runtime,
            workspaceURL: workspaceURL,
            promptFileURL: promptFileURL,
            systemPrompt: settings.systemPrompt,
            socketPath: socketPath
        )
        let didLaunch = launcher.createSurface(
            terminalID: terminalID,
            paneSessionID: paneSessionID,
            worktreePath: workspaceURL.path,
            extraInitialInput: command + "\r"
        )
        guard didLaunch else {
            status = FlowStatus(
                enabled: settings.enabled,
                running: false,
                message: "Flow State agent pane could not start"
            )
            return
        }

        liveTerminalID = terminalID
        livePaneSessionID = paneSessionID
        launchedSettings = settings
        paneSessions = [terminalID: paneSessionID]
        splitTree = SplitTree(root: .leaf(terminalID))
        focusedPaneSlotID = terminalID
        pendingRestartReason = nil
        updateStatus()
    }

    func stop() {
        if let terminalID = liveTerminalID {
            launcher.destroySurfaces(terminalIDs: [terminalID])
        }
        liveTerminalID = nil
        livePaneSessionID = nil
        launchedSettings = nil
        splitTree = SplitTree(root: nil)
        paneSessions = [:]
        focusedPaneSlotID = nil
        updateStatus()
    }

    func restart() throws {
        stop()
        try ensureRunning(settings: settings)
    }

    func settingsDidChange(
        enabled: Bool,
        runtime: FlowStateRuntime,
        systemPrompt: String,
        permissionMode: String
    ) {
        let next = FlowStateAgentSettings(
            enabled: enabled,
            runtime: runtime,
            systemPrompt: systemPrompt,
            permissionMode: permissionMode
        )
        let previousLaunched = launchedSettings
        settings = next

        if !enabled {
            stop()
            return
        }

        if liveTerminalID != nil,
           let previousLaunched {
            pendingRestartReason = previousLaunched == next
                ? nil
                : restartReason(from: previousLaunched, to: next)
        }
        updateStatus()
    }

    func reconcileSettingsFromUserDefaults() {
        let current = FlowStateAgentSettings.current()
        settingsDidChange(
            enabled: current.enabled,
            runtime: current.runtime,
            systemPrompt: current.systemPrompt,
            permissionMode: current.permissionMode
        )
    }

    func confirmPendingRestart() throws {
        guard pendingRestartReason != nil else { return }
        try restart()
        pendingRestartReason = nil
        updateStatus()
    }

    func requestRefresh(reason: String) {
        guard let terminalID = liveTerminalID else {
            status = FlowStatus(
                enabled: settings.enabled,
                running: false,
                message: "Flow State agent is not running"
            )
            return
        }

        let line = "Refresh requested by Graftty (\(reason)). Run `graftty flow context`, run `graftty flow request-status` if useful, then publish the updated recommendation with `graftty flow publish --stdin`."
        launcher.typeText(line + "\r", into: terminalID, claimEngagement: false)
        status = FlowStatus(
            enabled: settings.enabled,
            running: true,
            lastUpdatedAt: Date(),
            message: "Refresh requested"
        )
    }

    func focus(_ terminalID: PaneSlotID) {
        guard paneSessions[terminalID] != nil else { return }
        focusedPaneSlotID = terminalID
    }

    private func prepareWorkspace() throws {
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: promptFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try settings.systemPrompt.write(to: promptFileURL, atomically: true, encoding: .utf8)
    }

    private func updateStatus() {
        status = Self.makeStatus(
            settings: settings,
            running: liveTerminalID != nil,
            pendingRestartReason: pendingRestartReason
        )
    }

    private static func makeStatus(
        settings: FlowStateAgentSettings,
        running: Bool,
        pendingRestartReason: String?
    ) -> FlowStatus {
        if !settings.enabled {
            return FlowStatus(enabled: false, running: false, message: "Flow State is off")
        }
        if let pendingRestartReason {
            return FlowStatus(enabled: true, running: running, message: pendingRestartReason)
        }
        if running {
            return FlowStatus(enabled: true, running: true, message: "Flow State agent running")
        }
        return FlowStatus(enabled: true, running: false, message: "Flow State is idle")
    }

    private func restartReason(
        from old: FlowStateAgentSettings,
        to new: FlowStateAgentSettings
    ) -> String {
        var changes: [String] = []
        if old.runtime != new.runtime { changes.append("runtime") }
        if old.systemPrompt != new.systemPrompt { changes.append("system prompt") }
        if old.permissionMode != new.permissionMode { changes.append("permission mode") }
        return "Restart required for Flow State \(changes.joined(separator: ", ")) changes."
    }
}

import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("FlowStateAgentController")
struct FlowStateAgentControllerTests {
    @Test("ensureRunning is a no-op while Flow State is disabled")
    func disabledDoesNotLaunch() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: false, launcher: launcher)

        try controller.ensureRunning()

        #expect(launcher.launches.isEmpty)
        #expect(controller.status == FlowStatus(enabled: false, running: false, message: "Flow State is off"))
    }

    @Test("ensureRunning starts one persistent pane and does not duplicate it")
    func ensureRunningLaunchesOnce() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)

        try controller.ensureRunning()
        try controller.ensureRunning()

        #expect(launcher.launches.count == 1)
        #expect(controller.paneSessions.count == 1)
        #expect(controller.splitTree.allLeaves.count == 1)
        #expect(controller.focusedPaneSlotID == controller.splitTree.allLeaves.first)
        #expect(controller.status.running)
    }

    @Test("ensureRunning creates the Flow State workspace and writes the system prompt before launch")
    func ensureRunningWritesPromptFile() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher, systemPrompt: "Prompt with apostrophe: human's flow")

        try controller.ensureRunning()

        #expect(FileManager.default.fileExists(atPath: controller.workspaceURL.path))
        #expect(try String(contentsOf: controller.promptFileURL, encoding: .utf8) == "Prompt with apostrophe: human's flow")
        #expect(launcher.launches.first?.worktreePath == controller.workspaceURL.path)
    }

    @Test("stop destroys the Flow State pane and clears terminal state")
    func stopDestroysPane() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)
        try controller.ensureRunning()
        let terminalID = try #require(controller.splitTree.allLeaves.first)

        controller.stop()

        #expect(launcher.destroyed == [[terminalID]])
        #expect(controller.paneSessions.isEmpty)
        #expect(controller.splitTree.root == nil)
        #expect(controller.focusedPaneSlotID == nil)
        #expect(!controller.status.running)
    }

    @Test("restart stops the current pane and starts a replacement")
    func restartReplacesPane() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)
        try controller.ensureRunning()
        let firstID = try #require(controller.splitTree.allLeaves.first)

        try controller.restart()

        #expect(launcher.destroyed == [[firstID]])
        #expect(launcher.launches.count == 2)
        #expect(controller.status.running)
        #expect(controller.splitTree.allLeaves.first != firstID)
    }

    @Test("settings changes while running require explicit restart confirmation")
    func runningSettingsChangeMarksPendingRestart() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)
        try controller.ensureRunning()

        controller.settingsDidChange(
            enabled: true,
            runtime: .claude,
            systemPrompt: "new prompt",
            permissionMode: "manualOnly"
        )

        #expect(controller.pendingRestartReason?.contains("runtime") == true)
        #expect(launcher.launches.count == 1)

        try controller.confirmPendingRestart()

        #expect(controller.pendingRestartReason == nil)
        #expect(launcher.launches.count == 2)
    }

    @Test("reverting running settings to the launched values clears pending restart")
    func revertedSettingsClearPendingRestart() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)
        try controller.ensureRunning()

        controller.settingsDidChange(
            enabled: true,
            runtime: .claude,
            systemPrompt: "Flow prompt",
            permissionMode: "conservative"
        )
        #expect(controller.pendingRestartReason != nil)

        controller.settingsDidChange(
            enabled: true,
            runtime: .codex,
            systemPrompt: "Flow prompt",
            permissionMode: "conservative"
        )

        #expect(controller.pendingRestartReason == nil)
    }

    @Test("requestRefresh injects graftty flow commands into the running pane")
    func requestRefreshTypesFlowCommandLine() throws {
        let launcher = FakeFlowStateAgentLauncher()
        let controller = makeController(enabled: true, launcher: launcher)
        try controller.ensureRunning()

        controller.requestRefresh(reason: "manual refresh")

        let typed = try #require(launcher.typedLines.first)
        #expect(typed.terminalID == controller.splitTree.allLeaves.first)
        #expect(typed.text.contains("graftty flow context"))
        #expect(typed.text.contains("graftty flow request-status"))
        #expect(typed.text.contains("graftty flow publish --stdin"))
        #expect(typed.text.hasSuffix("\r"))
    }

    private func makeController(
        enabled: Bool,
        launcher: FakeFlowStateAgentLauncher,
        systemPrompt: String = "Flow prompt"
    ) -> FlowStateAgentController {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FlowStateAgentController(
            launcher: launcher,
            defaultDirectory: root,
            socketPath: root.appendingPathComponent("graftty.sock").path,
            settings: .init(
                enabled: enabled,
                runtime: .codex,
                systemPrompt: systemPrompt,
                permissionMode: "conservative"
            )
        )
    }
}

@MainActor
private final class FakeFlowStateAgentLauncher: FlowStateAgentLaunching {
    struct Launch: Equatable {
        let terminalID: PaneSlotID
        let paneSessionID: PaneSessionID
        let worktreePath: String
        let extraInitialInput: String
    }

    var launches: [Launch] = []
    var destroyed: [[PaneSlotID]] = []
    var typedLines: [(terminalID: PaneSlotID, text: String)] = []

    func createSurface(
        terminalID: PaneSlotID,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        extraInitialInput: String
    ) -> Bool {
        launches.append(Launch(
            terminalID: terminalID,
            paneSessionID: paneSessionID,
            worktreePath: worktreePath,
            extraInitialInput: extraInitialInput
        ))
        return true
    }

    func destroySurfaces(terminalIDs: [PaneSlotID]) {
        destroyed.append(terminalIDs)
    }

    func typeText(_ text: String, into terminalID: PaneSlotID, claimEngagement: Bool) {
        typedLines.append((terminalID, text))
    }
}

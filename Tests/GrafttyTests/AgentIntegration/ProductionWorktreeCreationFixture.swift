import AppKit
import Foundation
import GhosttyKit
import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

/// Shares model state with the isolated control server so production provider
/// hooks see the pane mappings created by AddWorktreeFlow. Control requests
/// still use HeadlessHostRuntime; this fixture does not exercise AppServices.
@MainActor
final class ProductionWorktreeCreationFixture {
    struct Created {
        let path: String
        let session: String
        let handle: SurfaceHandle
    }

    private let runtime: HeadlessHostRuntime
    private let root: URL
    private let manager: TerminalManager
    private let monitor = WorktreeMonitor()
    private let stats = WorktreeStatsStore(
        compute: { _, _, _, _ in .init(defaultBranch: nil, stats: nil) }, fetch: { _ in }
    )
    private var paths: Set<String> = []

    init(runtime: HeadlessHostRuntime, ownership: SessionDisplayOwnershipStore,
         attachments: RemoteAttachmentRegistry, root: URL) {
        self.runtime = runtime
        self.root = root
        _ = NSApplication.shared
        manager = TerminalManager(socketPath: runtime.configuration.socketPath)
        manager.zmxLauncher = runtime.launcher
        manager.displayOwnershipStore = ownership
        manager.remoteAttachmentRegistry = attachments
        manager.initialize()
    }

    /// `initialCommand` is the caller's real provider launch command, including
    /// its fake-endpoint environment. The Python controller must independently
    /// observe that provider's model request before mounting its mobile route.
    func create(repository: String, name: String, initialCommand: String) async throws -> Created {
        let binding = Binding<AppState>(get: { self.runtime.state }, set: { self.runtime.state = $0 })
        // Establish a concrete navigation intent before creating the other row.
        runtime.state.selectedWorktreePath = repository
        let selectedBefore = runtime.state.selectedWorktreePath
        let focusedBefore = runtime.state.worktree(forPath: repository)?.focusedPaneSlotID
        let path = repository + "/.worktrees/" + name
        let receipt = root.appendingPathComponent(name + "-production-launch-receipt.txt")
        let token = UUID().uuidString
        let markedCommand = "/usr/bin/printf %s " + WorktreeAgentLaunchCommand.shellLiteral(token)
            + " > " + WorktreeAgentLaunchCommand.shellLiteral(receipt.path) + "\n" + initialCommand
        var evidence = ["path": path, "selectedBefore": selectedBefore ?? "",
                        "focusedPaneBefore": focusedBefore?.id.uuidString ?? "",
                        "scope": "AddWorktreeFlow and TerminalManager startup; headless control server"]
        do {
            guard !initialCommand.isEmpty else { throw AgentIntegrationError("missing provider launch command") }
            guard runtime.state.worktree(forPath: repository) != nil else {
                throw AgentIntegrationError("original selected worktree is not registered")
            }
            switch AddWorktreeFlow.beginCreate(repoPath: repository, worktreeName: name,
                branch: .createNew(name: name), base: "HEAD", appState: binding) {
            case .success: paths.insert(path)
            case .failure(let error): throw AgentIntegrationError("production beginCreate failed: \(error)")
            }
            let result = await AddWorktreeFlow.finishCreate(repoPath: repository, worktreePath: path,
                branch: .createNew(name: name), base: "HEAD", baseResolutionPath: repository,
                appState: binding, worktreeMonitor: monitor, statsStore: stats, terminalManager: manager,
                teamEventDispatcher: TeamEventDispatcher(
                    inbox: TeamInbox(rootDirectory: runtime.configuration.stateDirectory.appendingPathComponent("team-inbox")),
                    preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" }),
                initialCommand: markedCommand, terminalStartTiming: .immediately)
            guard case .success(let created) = result else {
                throw AgentIntegrationError("production finishCreate failed: \(result)")
            }
            let pane = try #require(runtime.state.worktree(forPath: path)?.splitTree.allLeaves.first)
            let handle = try #require(manager.handle(for: pane))
            evidence["session"] = created.sessionName
            evidence["viewMounted"] = String(handle.view.window != nil)
            evidence["backendReady"] = String(await handle.waitForBackendStartup())
            evidence["initialInputAccepted"] = String(await manager.waitForExplicitInitialInputDelivery(for: pane))
            // Delivery acceptance precedes execution by the shell. Allow that
            // handoff to complete without mounting a view to stimulate startup.
            let deadline = ContinuousClock.now + .seconds(10)
            while (try? String(contentsOf: receipt, encoding: .utf8)) != token,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            evidence["launchReceiptMatches"] = String((try? String(contentsOf: receipt, encoding: .utf8)) == token)
            guard evidence["backendReady"] == "true", evidence["initialInputAccepted"] == "true",
                  evidence["launchReceiptMatches"] == "true" else {
                throw AgentIntegrationError("production background startup did not acknowledge the launch command")
            }
            guard handle.view.window == nil else { throw AgentIntegrationError("production startup mounted a terminal view") }
            guard runtime.state.selectedWorktreePath == selectedBefore else {
                throw AgentIntegrationError("production startup changed the selected worktree")
            }
            evidence["focusedPaneAfter"] = runtime.state.worktree(forPath: repository)?.focusedPaneSlotID?.id.uuidString ?? ""
            guard runtime.state.worktree(forPath: repository)?.focusedPaneSlotID == focusedBefore else {
                throw AgentIntegrationError("production startup changed the original worktree's focused pane")
            }
            evidence["result"] = "passed"
            try saveDiagnostics(name: name, path: path, evidence: evidence)
            return Created(path: created.worktreePath, session: created.sessionName, handle: handle)
        } catch {
            evidence["result"] = "failed"
            evidence["error"] = String(describing: error)
            do { try saveDiagnostics(name: name, path: path, evidence: evidence) }
            catch let diagnosticError {
                throw AgentIntegrationError("\(error); production startup diagnostics failed: \(diagnosticError)")
            }
            throw error
        }
    }

    /// Call before the isolated runtime shuts down, including failed runs.
    func close() {
        for path in paths {
            manager.destroySurfaces(terminalIDs: runtime.state.worktree(forPath: path)?.splitTree.allLeaves ?? [])
            monitor.stopWatchingWorktree(path)
            stats.clear(worktreePath: path)
        }
        paths.removeAll()
    }

    private func saveDiagnostics(name: String, path: String, evidence: [String: String]) throws {
        var evidence = evidence
        evidence["selectedAfter"] = runtime.state.selectedWorktreePath ?? ""
        if let worktree = runtime.state.worktree(forPath: path) {
            evidence["worktreeState"] = worktree.state.rawValue
            if let pane = worktree.splitTree.allLeaves.first {
                evidence["attachmentFailure"] = manager.attachmentFailures[pane]
                if let session = worktree.paneSessions[pane].map(ZmxLauncher.sessionName(for:)) {
                    evidence["session"] = session
                    let log = runtime.launcher.logFile(forSession: session)
                    if FileManager.default.fileExists(atPath: log.path) {
                        do { evidence["zmxLog"] = String(decoding: try Data(contentsOf: log), as: UTF8.self) }
                        catch { evidence["zmxLogReadError"] = String(describing: error) }
                    }
                }
                if let handle = manager.handle(for: pane) {
                    evidence["viewMounted"] = String(handle.view.window != nil)
                    var selection = ghostty_selection_s()
                    selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
                    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
                    selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
                    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
                    var text = ghostty_text_s()
                    if ghostty_surface_read_text(handle.surface, selection, &text) {
                        evidence["nativeText"] = text.text.map { String(cString: $0) } ?? ""
                        ghostty_surface_free_text(handle.surface, &text)
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: root.appendingPathComponent(name + "-production-startup.json"), options: .atomic)
    }
}

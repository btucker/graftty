import Foundation
import Testing
@testable import GrafttyKit

struct AgentLaunchObserverTests {
    @Test("@spec AGENT-6.118: When a UI-launched provider exits with graftty absent from its shell PATH, the application shall durably observe its exit without requiring a CLI helper lookup.")
    func observesExitWithoutHelperOnPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-no-helper-\(UUID().uuidString)")
        let providerBin = root.appendingPathComponent("provider-bin")
        try FileManager.default.createDirectory(at: providerBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = providerBin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 23\n".write(to: provider, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        var agent = ManagedAgent(name: "No CLI on PATH", provider: .codex, parent: nil, status: .starting)
        agent.paneSessionID = PaneSessionID()
        let prompts = root.appendingPathComponent("prompts with 'quotes'")
        let launch = try WorktreeAgentLaunchCommand.prepare(agent: .codex, prompt: "Task", exactCommand: nil,
            managedAgent: agent, promptDirectory: prompts)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(launch.command)]
        // No executable graftty exists anywhere in this environment, including the stale override.
        process.environment = ["PATH": providerBin.path, "GRAFTTY_AGENT_CLI": root.appendingPathComponent("missing-helper").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 23)
        let pending = try AgentLifecycleHandoff(directory: prompts.appendingPathComponent("lifecycle")).pending()
        let (file, event) = try #require(pending.first)
        #expect(event.agentID == agent.id && event.assignmentID == agent.assignmentID)
        #expect(event.sessionID == agent.paneSessionID && event.exitCode == 23)
        #expect(try #require(event.recordedAt) >= started.addingTimeInterval(-0.1))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test("@spec AGENT-6.98: When a managed provider is missing or exits, the launch observer shall report its actual exit code and exact reserved identities from the provider's launch environment.", arguments: [false, true])
    func observesActualLaunchEnvironment(providerExists: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-observer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if providerExists {
            let provider = root.appendingPathComponent("codex")
            try "#!/bin/sh\nexit 7\n".write(to: provider, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
        }
        var agent = ManagedAgent(name: "Test", provider: .codex, parent: nil, status: .starting)
        agent.paneSessionID = PaneSessionID()
        let launch = try WorktreeAgentLaunchCommand.prepare(agent: .codex, prompt: "Task", exactCommand: nil,
            managedAgent: agent, promptDirectory: root.appendingPathComponent("prompts"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(launch.command)]
        process.environment = ["PATH": root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == (providerExists ? 7 : 127))
        let events = try AgentLifecycleHandoff(directory: root.appendingPathComponent("prompts/lifecycle")).pending()
        let event = try #require(events.first?.1)
        #expect(event.agentID == agent.id)
        #expect(event.assignmentID == agent.assignmentID)
        #expect(event.sessionID == agent.paneSessionID)
        #expect(event.exitCode == (providerExists ? 7 : 127))

    }

    @Test("@spec AGENT-6.99: When a managed task uses the advertised maximum prompt budget, the application shall preserve the whole task and carry lifecycle identity separately without rejecting the staged launch.")
    func maximumTaskKeepsItsBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var agent = ManagedAgent(name: "Test", provider: .codex, parent: nil, status: .starting)
        agent.paneSessionID = PaneSessionID()
        let task = String(repeating: "x", count: WorktreeAgentLaunchCommand.maximumPromptBytes)
        let launch = try WorktreeAgentLaunchCommand.prepare(agent: .codex, prompt: task, exactCommand: nil,
            managedAgent: agent, promptDirectory: root)
        let staged = try String(contentsOf: #require(launch.promptFile), encoding: .utf8)
        #expect(staged == task)
        #expect(launch.command?.contains("GRAFTTY_MANAGED_AGENT_ID") == true)
    }
}

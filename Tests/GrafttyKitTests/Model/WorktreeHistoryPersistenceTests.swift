import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct WorktreeHistoryPersistenceTests {
    @Test func agentResponsesSurviveAcknowledgementAndPairedDeviceProjection() throws {
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task")
        let response = WorktreeHistory.AgentResponse(id: "response", text: "Implementing the quiet rail on both platforms.",
                                                    at: .now, runtime: "codex")
        worktree.recordAgentResponse(response)
        worktree.recordAgentResponse(response)
        worktree.acknowledgeAttention()
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        #expect(restored.history?.responses == [response])
        let metadata = SidebarHostNavigation.metadata(for: restored, projectID: "repo", folders: [])
        let wire = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(wire.history?.responses == [response])
    }

    @Test func humanInputPreventsMergingAcrossTheReply() {
        let date = Date(timeIntervalSince1970: 100)
        var worktree = WorktreeEntry(path: "/task", branch: "task")
        let recap = AttentionRecap(title: "Context", completed: "Before reply", next: "Review", checkpoint: "Layout")
        worktree.recordAgentStop(.init(agentName: "Codex", stoppedAt: date, recap: recap))
        worktree.recordUserInput(.init(text: "yes", at: date.addingTimeInterval(10)))
        var after = recap
        after.completed = "After reply"
        worktree.recordAgentStop(.init(agentName: "Codex", stoppedAt: date.addingTimeInterval(20), recap: after))
        #expect(worktree.brief?.history.map(\.completed) == ["Before reply", "After reply"])
        #expect(WorktreeTimeline(history: worktree.history, brief: worktree.brief).events.map(\.kind) == [.checkpoint, .user, .checkpoint])
    }

    @Test("@spec CONTEXT-13: When a provider emits a user-prompt hook, the application shall retain the actual user input once through the durable handoff, persist it independently of unread attention, and project creation and input history to paired devices before or after the first agent report.")
    func inputSurvivesReplayAcknowledgementAndProjection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoff = AttentionFileHandoff(rootDirectory: directory)
        let date = Date(timeIntervalSince1970: 100)
        try handoff.progress(worktree: "/repo/task", agentID: "agent", runtime: .codex,
            sessionID: "session", progressedAt: date, userPrompt: "Keep the user involved.")
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task", createdAt: date,
            creationOrigin: .init(date: date, source: .user))
        try handoff.consumeActivities { activity in
            if case .progress(let event) = activity, let input = event.userInput {
                worktree.recordUserInput(input)
                worktree.recordUserInput(input)
            }
        }
        worktree.acknowledgeAttention()
        #expect(worktree.history?.inputs.count == 1)
        #expect(worktree.brief == nil)
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        #expect(restored.history == worktree.history)
        let metadata = SidebarHostNavigation.metadata(for: restored, projectID: "repo", folders: [])
        let wire = try JSONDecoder().decode(SidebarWorktreeMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(wire.history == restored.history)
        #expect(wire.history?.inputs.first?.text == "Keep the user involved.")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktree)) as? [String: Any])
        legacy.removeValue(forKey: "history")
        let old = try JSONDecoder().decode(WorktreeEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.history?.origin?.source == .unknown)
    }
}

struct WorktreeHistoryReviewTests {
    @Test func providerHookHandoffsPreserveMixedHumanAndPeerProvenance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoff = AttentionFileHandoff(rootDirectory: directory)
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task")
        for runtime in [TeamHookRuntime.codex, .claude] {
            let peer = "<graftty-peer-message agent=\"/parent#\(runtime.rawValue)\" id=\"42\">Review completed.</graftty-peer-message>"
            let delivered = runtime == .claude
                ? "Another Claude session sent a message:\n<cross-session-message from-name=\"Graftty bridge\">\n\(peer)\n</cross-session-message>" : peer
            // These providers deliver peer content using a user role. The hook
            // payload's prompt, not that role, supplies the delivery provenance.
            let payload: [String: Any] = ["session_id": "fixture", "hook_event_name": "UserPromptSubmit",
                "prompt": "Keep my request.\n\n\(delivered)\n\n<system-reminder>Hook context</system-reminder>"]
            try handoff.progress(worktree: worktree.path, agentID: "fixture", runtime: runtime,
                sessionID: "fixture", userPrompt: WorktreeUserPrompt.text(from: payload))
        }
        try handoff.consumeActivities { event in
            if case .progress(let progress) = event, let input = progress.userInput {
                worktree.recordUserInput(input)
                worktree.recordUserInput(input)
            }
        }
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        let events = WorktreeTimeline(history: restored.history, brief: nil).events
        #expect(events.filter { $0.kind == .user }.map(\.completed) == ["Keep my request.", "Keep my request."])
        #expect(events.filter { $0.kind == .agentMessage }.map(\.completed) == ["Review completed.", "Review completed."])
        #expect(events.contains { $0.title == "Message from /parent#codex" })
        #expect(events.contains { $0.title == "Message from /parent#claude" })
    }

    @Test("@spec CONTEXT-16: When a provider submits generated startup or Graftty context, the application shall exclude it from human involvement, retain peer messages with agent provenance and later genuine user messages, and keep suppressed event replays idempotent.")
    func generatedPromptsAreNotHumanInput() throws {
        for prompt in [WorktreeAgentLaunchCommand.bootstrapPrompt,
                       "<graftty-system-message>Ready</graftty-system-message>",
                       "<graftty-forge-message provider=\"github\">CI passed</graftty-forge-message>",
                       "<system-reminder>Hook context</system-reminder>", "", "  "] {
            #expect(WorktreeUserPrompt.text(from: ["prompt": prompt]) == nil)
        }
        #expect(WorktreeUserPrompt.text(from: [:]) == nil)
        let peer = "<graftty-peer-message agent=\"/parent#claude\">Task</graftty-peer-message>"
        #expect(WorktreeUserPrompt.text(from: ["prompt": peer]) == peer)
        #expect(WorktreeUserPrompt.text(from: ["prompt": "Keep <graftty-peer-message> out of my history."]) != nil)
        var worktree = WorktreeEntry(path: "/task", branch: "task")
        let task = String(repeating: "a", count: 2000) + " delegated task"
        worktree.expectLaunchPrompt(task, runtime: .codex)
        let launched = WorktreeHistory.UserInput(text: task, at: .now, runtime: "codex")
        worktree.recordUserInput(launched)
        worktree = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        worktree.recordUserInput(launched)
        #expect(worktree.history?.inputs.isEmpty == true)
        // The same words typed later by a human must remain visible.
        worktree.recordUserInput(.init(text: task, at: .now, runtime: "codex"))
        #expect(worktree.history?.inputs.count == 1)
    }

    @Test func failedLaunchDoesNotHideAManuallyEnteredTask() {
        var worktree = WorktreeEntry(path: "/task", branch: "task")
        worktree.expectLaunchPrompt("fix this", runtime: .codex)
        worktree.cancelExpectedLaunch()
        worktree.recordUserInput(.init(text: "fix this", at: .now, runtime: "codex"))
        #expect(worktree.history?.inputs.count == 1)
    }

    @Test func launchMatchingUsesTheFullPromptAndSurvivesRelaunch() throws {
        var worktree = WorktreeEntry(path: "/task", branch: "task")
        let prefix = String(repeating: "a", count: 2000)
        worktree.expectLaunchPrompt(prefix + " automatic", runtime: .codex)
        worktree = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(worktree))
        worktree.recordUserInput(.init(text: prefix + " human", at: .now, runtime: "codex"))
        #expect(worktree.history?.inputs.count == 1)
        worktree.recordUserInput(.init(text: prefix + " automatic", at: .now, runtime: "codex"))
        #expect(worktree.history?.inputs.count == 2)
    }

    @Test("@spec CONTEXT-17: When a worktree is created on another device, the application shall retain the remote source worktree name separately from the destination repository used for dispatch and shall not treat the remote source path as a local navigation target.")
    func remoteCreationKeepsItsSourceName() {
        let request = RemoteWorktreeCreation(callerWorktree: "/source/.worktrees/actual-parent", project: "destination",
            worktreeName: "child", branchName: "child", existing: false, base: nil, command: nil,
            agentRuntime: nil, agentPrompt: nil, operationID: "id")
        let origin = request.historyOrigin(at: Date(timeIntervalSince1970: 100))
        #expect(origin.source == .worktree)
        #expect(origin.worktreeName == "actual-parent")
        #expect(origin.worktreePath == nil)
    }
}

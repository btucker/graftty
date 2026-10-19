import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct WorktreeHistoryPersistenceTests {
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
    @Test("@spec CONTEXT-16: When a provider submits a generated startup or Graftty message prompt, the application shall exclude it from human involvement while retaining later genuine user messages and keeping suppressed event replays idempotent.")
    func generatedPromptsAreNotHumanInput() throws {
        for prompt in [WorktreeAgentLaunchCommand.bootstrapPrompt,
                       "<graftty-peer-message agent=\"/parent\">Task</graftty-peer-message>",
                       "<graftty-system-message>Ready</graftty-system-message>",
                       "<graftty-forge-message provider=\"github\">CI passed</graftty-forge-message>", "", "  "] {
            #expect(WorktreeUserPrompt.text(from: ["prompt": prompt]) == nil)
        }
        #expect(WorktreeUserPrompt.text(from: [:]) == nil)
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

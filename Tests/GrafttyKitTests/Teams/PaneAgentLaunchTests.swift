import Foundation
import Testing
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("Pane add agent launch")
struct PaneAgentLaunchTests {
    @Test("@spec ATTN-1.25: When `graftty pane add` runs a command or agent, the application shall hand it to the new pane as initial shell input that runs once the shell is ready, rather than typing it into the PTY after the split, and shall run nothing for an empty or whitespace-only command.")
    func initialInputRunsOnShellReady() {
        #expect(PaneAgentLaunch.initialInput("pnpm test") == "pnpm test\r")
        #expect(PaneAgentLaunch.initialInput(nil) == nil)
        #expect(PaneAgentLaunch.initialInput("") == nil)
        #expect(PaneAgentLaunch.initialInput("  \n") == nil)
    }

    @Test("@spec AGENT-6.57: When `graftty pane add --agent` launches an agent with an initial task, the application shall save that task as a durable runtime-addressed inbox row only if no live agent of the same runtime already owns automatic delivery in the worktree and no initial task for that runtime is still pending there, so an existing implementer never receives or supersedes the added agent's task.")
    func durableRowOnlyWithoutLiveSameRuntimeOwner() throws {
        let worktree = "/repo/.worktrees/alice"
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        try WorktreeAgentLaunchCommand.saveInitialPrompt(
            "implement the feature", runtime: .claude, repo: repo,
            worktreePath: worktree, branchName: "alice", inbox: inbox
        )
        // A live Claude implementer owns delivery; the stale Codex record's
        // process start time no longer matches, so no Codex agent is live.
        let records = [
            TeamPresenceRecord(teamID: repo.path, worktree: worktree, runtime: .claude,
                paneSessionName: "graftty-implementer", pid: 101,
                processStartTimeMicroseconds: 1_001, registeredAt: Date(timeIntervalSince1970: 10)),
            TeamPresenceRecord(teamID: repo.path, worktree: worktree, runtime: .codex,
                paneSessionName: "graftty-stalecodex", pid: 102,
                processStartTimeMicroseconds: 2_002, registeredAt: Date(timeIntervalSince1970: 20)),
        ]
        let liveness = PaneAgentFakeLiveness(
            liveSessions: ["graftty-implementer", "graftty-stalecodex"],
            processStartTimes: [101: 1_001, 102: 9_999]
        )

        let saved = try PaneAgentLaunch.saveInitialPrompt(
            "review the diff", runtime: .claude, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox, presenceRecords: { records }, liveness: liveness
        )
        #expect(saved == nil)
        let pending = try inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree)
        #expect(pending.map(\.body) == ["implement the feature"])

        let savedWithoutOwner = try PaneAgentLaunch.saveInitialPrompt(
            "review the diff", runtime: .codex, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox, presenceRecords: { records }, liveness: liveness
        )
        #expect(savedWithoutOwner != nil)
        let rows = try inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree)
        let codexRow = try #require(rows.first { $0.to.runtime == "codex" })
        #expect(codexRow.kind == "agent_initial_prompt")
        #expect(codexRow.body == "review the diff")
        #expect(rows.contains { $0.body == "implement the feature" })

        let savedBlank = try PaneAgentLaunch.saveInitialPrompt(
            "  \n", runtime: .codex, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox, presenceRecords: { [] }, liveness: liveness
        )
        #expect(savedBlank == nil)
    }

    @Test("A starting same-runtime implementer keeps its pending initial task")
    func pendingImplementerTaskBlocksDurableRow() throws {
        let worktree = "/repo/.worktrees/alice"
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        // `worktree add --agent claude` saved this; the implementer has not
        // registered presence yet, so no delivery owner exists.
        try WorktreeAgentLaunchCommand.saveInitialPrompt(
            "implement the feature", runtime: .claude, repo: repo,
            worktreePath: worktree, branchName: "alice", inbox: inbox
        )
        let saved = try PaneAgentLaunch.saveInitialPrompt(
            "review the diff", runtime: .claude, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox, presenceRecords: { [] },
            liveness: PaneAgentFakeLiveness(liveSessions: [], processStartTimes: [:])
        )
        #expect(saved == nil)
        let pending = try inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree)
        #expect(pending.map(\.body) == ["implement the feature"])
    }

    @Test("An implementer that registers and takes its task during the check never receives the added task")
    func implementerRegisteringDuringCheckKeepsAddedTaskOut() throws {
        let worktree = "/repo/.worktrees/alice"
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        try WorktreeAgentLaunchCommand.saveInitialPrompt(
            "implement the feature", runtime: .claude, repo: repo,
            worktreePath: worktree, branchName: "alice", inbox: inbox
        )
        let implementerTask = try #require(
            inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree).first
        )
        // The presence read sees no implementer yet; right after it, the
        // implementer registers and acknowledges its own initial task.
        let saved = try PaneAgentLaunch.saveInitialPrompt(
            "review the diff", runtime: .claude, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox,
            presenceRecords: {
                defer {
                    _ = try? inbox.acknowledgeMessages(
                        teamID: repo.path, worktree: worktree, messageIDs: [implementerTask.id]
                    )
                }
                return []
            },
            liveness: PaneAgentFakeLiveness(liveSessions: [], processStartTimes: [:])
        )
        #expect(saved == nil)
        let pending = try inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree)
        #expect(!pending.contains { $0.body == "review the diff" })
    }

    @Test("A withdrawn initial task never reaches a later agent of that runtime")
    func withdrawnTaskLeavesNoPendingRow() throws {
        let worktree = "/repo/.worktrees/alice"
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TeamInbox(rootDirectory: root)
        // The split failed after the save, so no agent will run this task.
        let saved = try #require(try PaneAgentLaunch.saveInitialPrompt(
            "review the diff", runtime: .codex, repo: repo, worktreePath: worktree,
            branchName: "alice", inbox: inbox, presenceRecords: { [] },
            liveness: PaneAgentFakeLiveness(liveSessions: [], processStartTimes: [:])
        ))
        try PaneAgentLaunch.withdrawInitialPrompt(saved, inbox: inbox)
        #expect(try inbox.worktreePendingMessages(teamID: repo.path, recipientWorktree: worktree).isEmpty)
    }
}

private struct PaneAgentFakeLiveness: TeamDeliveryLivenessChecking {
    let liveSessions: Set<String>
    let processStartTimes: [Int32: Int64]

    func isLivePaneSession(_ sessionName: String) -> Bool {
        liveSessions.contains(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimes[pid]
    }
}

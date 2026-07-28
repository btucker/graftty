import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
import GrafttyKit

@Suite("CLI worktree removal")
struct CLIWorktreeRemovalTests {
    @Test("""
    @spec AGENT-5.7: `graftty worktree remove <worktree>` shall resolve a tracked worktree name, absolute path, or `.` for the current worktree; reject ambiguous names and the repository's main checkout; and route removal through the same application flow as the native Delete Worktree action so successful removal tears down its panes, removes it from the UI and per-path stores, emits team departure state, and preserves its Git branch. A normal removal shall fail when Git reports modified, staged, or untracked files, include `git status --short` in the CLI error, and instruct the user to rerun with `--force`; `--force` shall mirror the UI's Force Delete action. The CLI shall poll an asynchronous operation status so slow removal does not exceed the control socket request timeout. The built-in session prompt shall warn that removing `.` closes the worktree's panes and may end the current session before the CLI prints success.
    """)
    func helpDocumentsBranchPreservationAndForce() {
        let help = WorktreeRemove.helpMessage()

        #expect(help.contains("preserving its branch"))
        #expect(help.contains("--force"))
        #expect(help.contains("untracked"))
        #expect(help.contains("graftty team list"))
        #expect(
            TeamInstructionsRenderer.defaultTemplate.contains(
                "graftty worktree remove <worktree> [--force]"
            )
        )
        #expect(
            TeamInstructionsRenderer.defaultTemplate.contains(
                "Removing `.` closes its panes"
            )
        )
    }

    @Test func parsedForceFlagReachesProtocolRequest() throws {
        let command = try WorktreeRemove.parse(["feature-auth", "--force"])
        let request = command.removalRequest(
            worktreePath: "/repo/.worktrees/feature-auth"
        )

        guard case let .removeWorktree(worktreePath, force) = request else {
            Issue.record("expected removeWorktree request")
            return
        }
        #expect(worktreePath == "/repo/.worktrees/feature-auth")
        #expect(force)
    }

    @Test func resolvesTrackedNameAndAbsolutePath() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "graftty-remove-state-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let worktreePath = stateDirectory
            .appendingPathComponent("feature-auth", isDirectory: true)
            .path
        let state = AppState(repos: [
            RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [
                    WorktreeEntry(path: "/repo", branch: "main"),
                    WorktreeEntry(
                        path: worktreePath,
                        branch: "feature/auth"
                    ),
                ]
            ),
        ])
        try state.save(to: stateDirectory)

        #expect(
            WorktreeRemove.resolveTarget(
                "feature/auth",
                stateDirectory: stateDirectory
            ) == .resolved(worktreePath)
        )
        #expect(
            WorktreeRemove.resolveTarget(
                worktreePath,
                stateDirectory: stateDirectory
            ) == .resolved(worktreePath)
        )
        #expect(
            WorktreeRemove.resolveTarget(
                "missing",
                stateDirectory: stateDirectory
            ) == .unknown
        )
    }

    @Test func rejectsAmbiguousNamesAcrossRepositories() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "graftty-remove-ambiguous-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let state = AppState(repos: [
            RepoEntry(
                path: "/repo-a",
                displayName: "repo-a",
                worktrees: [
                    WorktreeEntry(
                        path: "/repo-a/.worktrees/feature",
                        branch: "feature"
                    ),
                ]
            ),
            RepoEntry(
                path: "/repo-b",
                displayName: "repo-b",
                worktrees: [
                    WorktreeEntry(
                        path: "/repo-b/.worktrees/feature",
                        branch: "feature"
                    ),
                ]
            ),
        ])
        try state.save(to: stateDirectory)

        #expect(
            WorktreeRemove.resolveTarget(
                "feature",
                stateDirectory: stateDirectory
            ) == .ambiguous([
                "/repo-a/.worktrees/feature",
                "/repo-b/.worktrees/feature",
            ])
        )
    }

    @Test func forceableFailureIncludesStatusAndRetryInstruction() {
        let status = WorktreeRemoveStatus(
            operationID: "remove-1",
            state: .failed,
            worktreePath: "/repo/.worktrees/feature",
            error: "contains modified or untracked files",
            forceAllowed: true,
            shortStatus: " M tracked.txt\n?? scratch.txt"
        )

        let message = WorktreeRemove.failureMessage(status)
        #expect(message.contains("contains modified or untracked files"))
        #expect(message.contains(" M tracked.txt"))
        #expect(message.contains("?? scratch.txt"))
        #expect(message.contains("Rerun with --force"))
    }

    @MainActor
    @Test func removalStorePreservesFailureDetailsAcrossPolling() {
        let store = CLIWorktreeRemovalStore(terminalRetention: 60)
        let started = store.begin(
            worktreePath: "/repo/.worktrees/feature",
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(started.state == .pending)

        store.markFailed(
            operationID: started.operationID,
            error: "dirty",
            forceAllowed: true,
            shortStatus: "?? scratch.txt",
            now: Date(timeIntervalSince1970: 101)
        )
        let failed = store.status(
            operationID: started.operationID,
            now: Date(timeIntervalSince1970: 102)
        )

        #expect(failed?.state == .failed)
        #expect(failed?.worktreePath == "/repo/.worktrees/feature")
        #expect(failed?.forceAllowed == true)
        #expect(failed?.shortStatus == "?? scratch.txt")
    }

    @MainActor
    @Test func removalStoreMarksSuccessfulRemoval() {
        let store = CLIWorktreeRemovalStore()
        let started = store.begin(
            worktreePath: "/repo/.worktrees/feature"
        )

        #expect(store.hasPendingRemoval(worktreePath: started.worktreePath))
        store.markRemoved(operationID: started.operationID)

        #expect(store.status(operationID: started.operationID)?.state == .removed)
        #expect(!store.hasPendingRemoval(worktreePath: started.worktreePath))
    }
}

import Foundation
import Testing
@testable import GrafttyCommandUI

@Suite("Automatic Add Worktree names")
struct WorktreeNameSuggestionTests {
    @Test("@spec GIT-5.40: When the user submits Add Worktree on Mac or mobile with a blank worktree name, the application shall request a brief on-device Apple Intelligence name using the optional task description, normalize it to lowercase kebab-case of at most four words and 40 characters, and use it for an unnamed new branch while preserving explicit worktree and branch names.")
    func blankNamesUseModelAndPreserveBranches() async throws {
        let names = try await WorktreeNameSuggestion.resolve(
            worktreeName: "  ", branchName: "", repositoryName: "App",
            taskDescription: "Fix login timeout", generate: { prompt in
                #expect(prompt.contains("Fix login timeout"))
                #expect(prompt.contains("App"))
                return "`Fix_Login/Timeout!`\nExplanation"
            }
        )
        #expect(names.worktree == "fix-login-timeout")
        #expect(names.branch == names.worktree)
        for existing in [false, true] {
            let custom = try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "feature/explicit", existing: existing,
                repositoryName: "App", taskDescription: "", generate: { _ in "Cedar Stream" }
            )
            #expect(custom.worktree == "cedar-stream")
            #expect(custom.branch == "feature/explicit")
        }
        let explicit = try await WorktreeNameSuggestion.resolve(
            worktreeName: "My-Worktree", branchName: "feature/Manual", repositoryName: "App",
            taskDescription: "", generate: { _ in
                Issue.record("An explicit name must bypass the model")
                return nil
            }
        )
        #expect(explicit.worktree == "My-Worktree")
        #expect(explicit.branch == "feature/Manual")
    }

    @Test("@spec GIT-5.41: If Apple Intelligence is unavailable, fails, exceeds an eight-second generation budget, or returns no usable name, then the application shall use a brief unique kebab-case fallback; if name generation is cancelled, then the application shall stop submission.")
    func unavailableModelFallsBackAndCancellationStopsSubmission() async throws {
        struct Failure: Error {}
        let generators: [WorktreeNameSuggestion.Generator] = [
            { _ in nil }, { _ in throw Failure() }, { _ in "!!!" }, { _ in "" },
        ]
        var fallbacks: Set<String> = []
        for generate in generators {
            let names = try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "", repositoryName: "App",
                taskDescription: "", generate: generate
            )
            #expect(names.worktree.hasPrefix("worktree-"))
            #expect(names.worktree.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil)
            #expect(names.worktree.count <= 40)
            #expect(names.branch == names.worktree)
            fallbacks.insert(names.worktree)
        }
        #expect(fallbacks.count == generators.count)
        await #expect(throws: CancellationError.self) {
            _ = try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "", repositoryName: "App",
                taskDescription: "", generate: { _ in throw CancellationError() }
            )
        }
    }

    @Test("A slow model falls back and a cancelled submission never falls back")
    func slowModelAndCancelledTask() async throws {
        let names = try await WorktreeNameSuggestion.resolve(
            worktreeName: "", branchName: "", repositoryName: "App", taskDescription: "",
            timeout: .milliseconds(1), generate: { _ in
                try await Task.sleep(for: .seconds(60))
                return "too-late"
            }
        )
        #expect(names.worktree.hasPrefix("worktree-"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "", repositoryName: "App", taskDescription: "",
                generate: { _ in Issue.record("Cancelled submission ran the model"); return nil }
            )
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("Blank worktree and new branch can submit; existing branches still require selection")
    func submissionPolicy() {
        #expect(WorktreeNameSuggestion.canSubmit(worktreeName: "", branchName: "", existing: false))
        #expect(WorktreeNameSuggestion.canSubmit(worktreeName: "", branchName: "feature", existing: true))
        #expect(!WorktreeNameSuggestion.canSubmit(worktreeName: "", branchName: "", existing: true))
        #expect(!WorktreeNameSuggestion.canSubmit(worktreeName: "feature", branchName: "", existing: false))
    }

    @Test("Generated names are bounded and cannot introduce Git ref or path syntax")
    func normalizesGeneratedNames() {
        #expect(WorktreeNameSuggestion.normalized("../../Fix AUTH.lock@{oops}//") == "fix-auth-lock-oops")
        #expect(WorktreeNameSuggestion.normalized("one two three four five") == "one-two-three-four")
        #expect(WorktreeNameSuggestion.normalized(String(repeating: "A", count: 100)) == String(repeating: "a", count: 40))
        #expect(WorktreeNameSuggestion.normalized("\n\"Cedar Stream\"\n") == "cedar-stream")
        #expect(WorktreeNameSuggestion.normalized("🎉") == nil)
    }
}

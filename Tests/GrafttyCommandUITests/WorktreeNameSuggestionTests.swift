import Foundation
import Testing
@testable import GrafttyCommandUI

@Suite("Automatic Add Worktree names")
struct WorktreeNameSuggestionTests {
    private actor UnresponsiveModel {
        private var reply: CheckedContinuation<String?, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var watchdogFired = false

        func generate() async -> String? {
            if released { return "late-result" }
            return await withCheckedContinuation {
                reply = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if reply != nil || released { return }
            await withCheckedContinuation { started = $0 }
        }

        func release(watchdog: Bool = false) {
            watchdogFired = watchdogFired || watchdog
            released = true
            reply?.resume(returning: "late-result")
            reply = nil
            started?.resume()
            started = nil
        }
    }

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

    @Test("@spec GIT-5.41: If Apple Intelligence is unavailable, fails, exceeds an eight-second generation budget, returns no usable name, or proposes a name already known in the repository, then the application shall use a brief unique kebab-case fallback; if name generation is cancelled, then the application shall stop submission.")
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

    @Test("Known names reject automatic collisions while explicit names remain unchanged")
    func generatedNamesAvoidKnownCollisions() async throws {
        let reserved: Set<String> = ["Fix-Login", "custom-directory"]
        for reply in ["fix-login", "custom-directory"] {
            let names = try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "", repositoryName: "App", taskDescription: "",
                reservedNames: reserved, generate: { _ in reply }
            )
            #expect(names.worktree.hasPrefix("worktree-"))
            #expect(names.branch == names.worktree)
        }
        let explicit = try await WorktreeNameSuggestion.resolve(
            worktreeName: "custom-directory", branchName: "feature/explicit", repositoryName: "App",
            taskDescription: "", reservedNames: reserved, generate: { _ in
                Issue.record("Explicit names must bypass generation and collision fallback")
                return nil
            }
        )
        #expect(explicit.worktree == "custom-directory")
        #expect(explicit.branch == "feature/explicit")
    }

    @Test("Timeout and cancellation return even when the model ignores cancellation", arguments: [false, true])
    func unresponsiveModelDoesNotHoldSubmission(cancelling: Bool) async throws {
        let model = UnresponsiveModel()
        let task = Task {
            try await WorktreeNameSuggestion.resolve(
                worktreeName: "", branchName: "", repositoryName: "App", taskDescription: "",
                timeout: cancelling ? .seconds(60) : .milliseconds(10),
                generate: { _ in await model.generate() }
            )
        }
        // Release a broken implementation too, so a regression fails rather than hangs.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await model.release(watchdog: true)
        }
        await model.waitUntilStarted()
        if cancelling {
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else {
            let names = try await task.value
            #expect(names.worktree.hasPrefix("worktree-"))
        }
        #expect(await !model.watchdogFired)
        watchdog.cancel()
        await model.release()
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

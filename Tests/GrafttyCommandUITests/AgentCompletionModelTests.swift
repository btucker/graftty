import Combine
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@Suite @MainActor
struct AgentCompletionModelTests {
    @Test("@spec TEAM-15.17: While agent completion is idle, the application shall invalidate its input boundary without publishing unchanged picker state or triggering a terminal view refresh.")
    func idleBoundaryInvalidationDoesNotPublish() {
        let model = AgentCompletionModel()
        model.loadCandidates = { [] }
        model.onInsertText = { _ in }
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        model.invalidateBoundary()
        model.invalidateBoundary()
        model.cancel(preserveLiteral: true)
        #expect(publications == 0)
        #expect(!model.handleText("%"), "An idle reset must still invalidate the word boundary")
        model.cancel(preserveLiteral: false)
        #expect(publications == 0)
        #expect(model.handleText("%"), "A deliberate cancel must still restore a clean word boundary")
        #expect(publications > 0, "Opening the picker must publish changed state")
        model.cancel(preserveLiteral: false)
    }

    private func candidate(_ name: String, project: String = "/repo", host: String = "This Mac") -> AgentCompletionCandidate {
        .init(address: "/repo/\(name)#codex", projectPath: project, projectName: "Project", worktreePath: "/repo/\(name)", worktreeName: name, hostName: host, runtime: "codex")
    }

    @Test("@spec TEAM-15.11: While remote agent discovery is pending for a local Mac terminal, the application shall display and permit selection of available local agents and ignore later discovery updates after acceptance.")
    func localCandidatesArriveBeforeRemoteDiscovery() async {
        let model = AgentCompletionModel()
        var update: AgentCompletionModel.CatalogUpdate?
        var resume: CheckedContinuation<[AgentCompletionCandidate], Never>?
        model.onInsertText = { _ in }
        model.loadCandidatesWithUpdates = { publish in
            update = publish
            publish([candidate("local")])
            return await withCheckedContinuation { resume = $0 }
        }
        #expect(model.handleText("%"))
        for _ in 0..<20 where model.candidates.isEmpty { await Task.yield() }
        #expect(model.isLoading)
        #expect(model.candidates.count == 1)
        #expect(model.handleKey(.accept))
        update?([candidate("late")])
        resume?.resume(returning: [candidate("remote")])
        #expect(!model.isActive)
        #expect(model.candidates.isEmpty)
    }

    @Test("@spec TEAM-15.1: When a user types a percent prefix at a word boundary in a native Mac or iOS terminal, the application shall buffer the completion token locally, filter agent suggestions, and insert only the selected address without submitting terminal input.")
    func buffersAndAccepts() async {
        let model = AgentCompletionModel()
        var inserted: [String] = []
        model.onInsertText = { inserted.append($0) }
        model.loadCandidates = { [candidate("fix")] }
        #expect(model.handleText("%"))
        #expect(model.handleText("fi"))
        #expect(model.query == "fi")
        #expect(inserted.isEmpty)
        await model.waitForLoad()
        #expect(model.handleKey(.accept))
        #expect(inserted == ["/repo/fix#codex"])
        #expect(!model.isActive)
    }

    @Test("@spec TEAM-15.2: When percent completion is dismissed or followed by a delimiter, the application shall preserve the literal token, and shall leave percentages within words and pasted text unchanged.")
    func literalFallback() {
        let model = AgentCompletionModel()
        var inserted: [String] = []
        model.onInsertText = { inserted.append($0) }
        model.loadCandidates = { [] }
        #expect(!model.handleText("5"))
        #expect(!model.handleText("%"))
        #expect(!model.handleText(" "))
        #expect(!model.handleText("%pasted"))
        #expect(!model.handleText(" "))
        #expect(model.handleText("%"))
        #expect(model.handleText("no-match"))
        #expect(model.handleKey(.escape))
        #expect(inserted == ["%no-match"])
        #expect(model.handleText("%") == false) // Still within the flushed word.
        #expect(!model.handleText(" "))
        #expect(model.handleText("%"))
        #expect(!model.handleText(" "))
        #expect(inserted.last == "%")
    }

    @Test("@spec TEAM-15.3: While agent completion is open, the application shall consume selection and deletion keys, preserve a valid selection after filtering, and ignore catalog replies from a dismissed picker.")
    func navigationDeletionAndStaleLoad() async {
        let model = AgentCompletionModel()
        var inserted = ""
        model.onInsertText = { inserted += $0 }
        model.loadCandidates = { [candidate("a"), candidate("b")] }
        #expect(model.handleText("%"))
        await model.waitForLoad()
        #expect(model.handleKey(.down))
        #expect(model.selectedID == "/repo/b#codex")
        #expect(model.handleText("/a#"))
        #expect(model.selectedID == "/repo/a#codex")
        #expect(model.handleBackspace())
        #expect(model.handleBackspace())
        #expect(model.handleBackspace())
        #expect(model.query.isEmpty)
        #expect(model.handleBackspace())
        #expect(!model.isActive)
        #expect(inserted.isEmpty)
        model.loadCandidates = {
            try? await Task.sleep(for: .milliseconds(10))
            return [candidate("stale")]
        }
        #expect(model.handleText("%"))
        model.cancel(preserveLiteral: false)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.candidates.isEmpty)
        #expect(!model.isActive)
    }

    @Test("@spec TEAM-15.4: When native agent completion lists candidates, the application shall rank the current project first, match worktree, project, host and provider text case-insensitively, and distinguish identical worktree names by their routing addresses.")
    func rankingAndMatching() {
        let current = candidate("local")
        let other = candidate("elsewhere", project: "/other")
        let remote = AgentCompletionCandidate(address: "graftty-mac://host/repo/local#claude", projectPath: "graftty-mac://host/repo", projectName: "Remote project", worktreePath: "graftty-mac://host/repo/local", worktreeName: "local", hostName: "Build Mac", runtime: "claude")
        let candidates = [other, remote, current]
        #expect(AgentCompletionCandidate.matching(candidates, query: "", currentWorktreePath: current.worktreePath).first == current)
        #expect(AgentCompletionCandidate.matching(candidates, query: "", currentWorktreePath: "/repo/quiet").first == current)
        #expect(AgentCompletionCandidate.matching(candidates, query: "BUILD CLAUDE", currentWorktreePath: nil) == [remote])
    }
}

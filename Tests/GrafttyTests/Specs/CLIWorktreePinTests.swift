import ArgumentParser
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

@Suite("@spec AGENT-5.21: When graftty worktree pin or unpin is invoked, the application shall resolve the caller's worktree by default or a supplied tracked name or absolute path, reject ambiguous or unavailable targets and in-flight changes, persist idempotent pin state through the sidebar model without changing panes or instructions, and keep the default-branch checkout always pinned.")
struct CLIWorktreePinTests {
    @Test("@spec TEAM-4.13: When agents establish durable roles, the bundled Graftty Team skill shall demonstrate supported CLI commands for pinning the current or another tracked worktree, unpinning, and explicitly removing a pinned worktree, and explain role instruction files and retention after PR or MR resolution.")
    func skillPinningExamplesUseSupportedCLICommands() throws {
        let skill = try GrafttyTeamSkillText.load()
        let examples = skill.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            $0.hasPrefix("graftty worktree pin") || $0.hasPrefix("graftty worktree unpin") || $0.hasPrefix("graftty worktree remove")
        }
        #expect(!examples.isEmpty)
        for example in examples {
            let arguments = example.split(separator: " ").dropFirst().map(String.init)
            let command = try GrafttyCLI.parseAsRoot(arguments)
            #expect(["pin", "unpin", "remove"].contains(type(of: command).configuration.commandName ?? ""))
        }
    }

    @Test func commandsAreRegistered() throws {
        for name in ["pin", "unpin"] {
            let command = try GrafttyCLI.parseAsRoot(["worktree", name])
            #expect(type(of: command).configuration.commandName == name)
        }
    }

    @Test func requestCodecRoundTripsAndRejectsMissingPinState() throws {
        for pinned in [true, false] {
            let data = Data("{\"type\":\"set_worktree_pinned\",\"worktree_path\":\"/repo/.worktrees/release\",\"is_pinned\":\(pinned)}".utf8)
            let request = try JSONDecoder().decode(NotificationMessage.self, from: data)
            #expect(request.expectsResponse)
            let output = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            #expect(output["worktree_path"] as? String == "/repo/.worktrees/release")
            #expect(output["is_pinned"] as? Bool == pinned)
        }
        let capability = try JSONDecoder().decode(NotificationMessage.self,
            from: Data(#"{"type":"worktree_pin_capability"}"#.utf8))
        #expect(capability.expectsResponse)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NotificationMessage.self,
                from: Data(#"{"type":"set_worktree_pinned","worktree_path":"/repo"}"#.utf8))
        }
    }

    @Test func omittedOrDotTargetUsesCallingWorktreeAndChecksCapability() throws {
        for target: String? in [nil, "."] {
            var requests: [NotificationMessage] = []
            var lines: [String] = []
            try WorktreePinCommand.run(target: target, isPinned: true,
                resolveCurrent: { "/repo/.worktrees/release" }, send: { requests.append($0); return .ok },
                writeLine: { lines.append($0) })
            #expect(requests.count == 2)
            let probe = try #require(requests.first)
            let request = try #require(requests.last)
            let probeJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(probe)) as? [String: Any])
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            #expect(probeJSON["type"] as? String == "worktree_pin_capability")
            #expect(json["type"] as? String == "set_worktree_pinned")
            #expect(json["worktree_path"] as? String == "/repo/.worktrees/release")
            #expect(json["is_pinned"] as? Bool == true)
            #expect(lines.count == 1)
            #expect(lines[0].contains("pinned worktree="))
        }
    }

    @Test func nameAndPathResolveAnotherWorktreeAfterItsBranchChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetPath = "/repo/.worktrees/release"
        let state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo",
            worktrees: [WorktreeEntry(path: targetPath, branch: "new-release-branch")])])
        try state.save(to: directory)
        for target in ["release", targetPath, "/repo/.worktrees/../.worktrees/release"] {
            var requests: [NotificationMessage] = []
            try WorktreePinCommand.run(target: target, isPinned: false, stateDirectory: directory,
                resolveCurrent: { Issue.record("named target must not resolve current worktree"); return "/wrong" },
                send: { requests.append($0); return .ok }, writeLine: { _ in })
            let request = try #require(requests.last)
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            #expect(json["worktree_path"] as? String == targetPath)
            #expect(json["is_pinned"] as? Bool == false)
        }
    }

    @Test func unknownAndAmbiguousNamesFailBeforeSending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-pin-ambiguous-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repos: ["/repo-a", "/repo-b"].map { root in
            RepoEntry(path: root, displayName: root, worktrees: [WorktreeEntry(path: root + "/.worktrees/release", branch: "release")])
        })
        try state.save(to: directory)
        for target in ["release", "missing", "/unknown"] {
            #expect(throws: ValidationError.self) {
                try WorktreePinCommand.run(target: target, isPinned: true, stateDirectory: directory,
                    send: { _ in Issue.record("invalid target must not send a request"); return .ok }, writeLine: { _ in })
            }
        }
    }

    @Test func unsupportedAppFailsBeforeSendingMutation() {
        var sent = 0
        #expect(throws: (any Error).self) {
            try WorktreePinCommand.run(target: nil, isPinned: true, resolveCurrent: { "/repo/.worktrees/release" },
                send: { _ in sent += 1; return .error("unsupported") }, writeLine: { _ in })
        }
        #expect(sent == 1)
    }

    @Test func pinAndUnpinAreIdempotentAndPersistOnlyTheFlag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-pin-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var worktree = WorktreeEntry(path: "/repo/.worktrees/release", branch: "release", state: .running,
            splitTree: SplitTree(root: .leaf(PaneSlotID())))
        _ = worktree.ensurePaneSession(for: worktree.splitTree.allLeaves[0])
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [worktree])])
        #expect(WorktreePinRequestHandler.handle(worktreePath: worktree.path, isPinned: true, state: &state) == .ok)
        #expect(WorktreePinRequestHandler.handle(worktreePath: worktree.path, isPinned: true, state: &state) == .ok)
        var expected = worktree
        expected.isPinned = true
        #expect(state.repos[0].worktrees == [expected])
        try state.save(to: directory)
        state = try AppState.load(from: directory)
        #expect(state.repos[0].worktrees[0].isPinned)
        #expect(WorktreePinRequestHandler.handle(worktreePath: worktree.path, isPinned: false, state: &state) == .ok)
        #expect(WorktreePinRequestHandler.handle(worktreePath: worktree.path, isPinned: false, state: &state) == .ok)
        #expect(state.repos[0].worktrees == [worktree])
    }

    @Test func defaultCheckoutAlwaysPinnedAndInFlightChangesAreRejected() {
        let home = WorktreeEntry(path: "/repo", branch: "trunk")
        let creating = WorktreeEntry(path: "/repo/.worktrees/new", branch: "new", state: .creating)
        let stale = WorktreeEntry(path: "/repo/.worktrees/gone", branch: "gone", state: .stale)
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [home, creating, stale])])
        let original = state.repos[0]
        #expect(WorktreePinRequestHandler.handle(worktreePath: home.path, isPinned: true, state: &state) == .ok)
        for (path, pinned) in [(home.path, false), (creating.path, true), (stale.path, true), ("/unknown", true)] {
            guard case .error = WorktreePinRequestHandler.handle(worktreePath: path, isPinned: pinned, state: &state) else {
                Issue.record("invalid pin change should fail"); continue
            }
        }
        #expect(state.repos[0] == original)
    }

    @Test func pinningViaCLIProtectsResolvedPullRequestsAndMergeRequests() {
        let worktree = WorktreeEntry(path: "/repo/.worktrees/release", branch: "release")
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [worktree])])
        #expect(WorktreePinRequestHandler.handle(worktreePath: worktree.path, isPinned: true, state: &state) == .ok)
        for resolution in [PRInfo.State.merged, .closed] {
            #expect(PRResolutionOfferAlert.configuration(prNumber: 7, prTitle: "Release", state: resolution,
                isPinned: state.repos[0].worktrees[0].isPinned) == nil)
        }
    }
}

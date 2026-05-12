import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team delivery pane resolver")
struct TeamDeliveryPaneResolverTests {
    @Test("Stale codex presence in a shell-only pane is not a delivery target.")
    func staleCodexPresenceWithShellOnlyPaneSkips() {
        let paneID = UUID()
        let records = [
            record(runtime: .codex, paneSessionName: "graftty-aaaaaaaa")
        ]
        let resolver = TeamDeliveryPaneResolver(
            processTree: StubDeliveryProcessTreeWalker(descendantsByRoot: [100: [100, 101]]),
            commandReader: StubProcessCommandReader(commandsByPID: [
                100: "/bin/zsh",
                101: "git status",
            ])
        )

        let paneIDs = resolver.paneIDs(
            records: records,
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneIDForSessionName: { $0 == "graftty-aaaaaaaa" ? paneID : nil },
            shellPIDForPaneID: { $0 == paneID ? 100 : nil }
        )

        #expect(paneIDs.isEmpty)
    }

    @Test("Live codex process under a registered pane is a delivery target.")
    func liveCodexPresenceDelivers() {
        let paneID = UUID()
        let records = [
            record(runtime: .codex, paneSessionName: "graftty-aaaaaaaa")
        ]
        let resolver = TeamDeliveryPaneResolver(
            processTree: StubDeliveryProcessTreeWalker(descendantsByRoot: [100: [100, 101]]),
            commandReader: StubProcessCommandReader(commandsByPID: [
                100: "/bin/zsh",
                101: "/opt/homebrew/bin/codex",
            ])
        )

        let paneIDs = resolver.paneIDs(
            records: records,
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneIDForSessionName: { $0 == "graftty-aaaaaaaa" ? paneID : nil },
            shellPIDForPaneID: { $0 == paneID ? 100 : nil }
        )

        #expect(paneIDs == [paneID])
    }

    @Test("Node-launched codex wrapper under the shell is recognized.")
    func nodeLaunchedCodexWrapperDelivers() {
        let paneID = UUID()
        let records = [
            record(runtime: .codex, paneSessionName: "graftty-aaaaaaaa")
        ]
        let resolver = TeamDeliveryPaneResolver(
            processTree: StubDeliveryProcessTreeWalker(descendantsByRoot: [100: [100, 101]]),
            commandReader: StubProcessCommandReader(commandsByPID: [
                100: "/bin/zsh",
                101: "/opt/homebrew/bin/node /opt/homebrew/bin/codex",
            ])
        )

        let paneIDs = resolver.paneIDs(
            records: records,
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneIDForSessionName: { $0 == "graftty-aaaaaaaa" ? paneID : nil },
            shellPIDForPaneID: { $0 == paneID ? 100 : nil }
        )

        #expect(paneIDs == [paneID])
    }

    @Test("Register helper command line is not mistaken for a running codex agent.")
    func registerHelperDoesNotCountAsAgent() {
        let paneID = UUID()
        let records = [
            record(runtime: .codex, paneSessionName: "graftty-aaaaaaaa")
        ]
        let resolver = TeamDeliveryPaneResolver(
            processTree: StubDeliveryProcessTreeWalker(descendantsByRoot: [100: [100, 101]]),
            commandReader: StubProcessCommandReader(commandsByPID: [
                100: "/bin/zsh",
                101: "/usr/local/bin/graftty team register --runtime codex",
            ])
        )

        let paneIDs = resolver.paneIDs(
            records: records,
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneIDForSessionName: { $0 == "graftty-aaaaaaaa" ? paneID : nil },
            shellPIDForPaneID: { $0 == paneID ? 100 : nil }
        )

        #expect(paneIDs.isEmpty)
    }

    @Test("Live claude process under a registered pane is a delivery target for claude resolution.")
    func liveClaudePresenceDelivers() {
        let paneID = UUID()
        let records = [
            record(runtime: .claude, paneSessionName: "graftty-aaaaaaaa")
        ]
        let resolver = TeamDeliveryPaneResolver(
            processTree: StubDeliveryProcessTreeWalker(descendantsByRoot: [100: [100, 101]]),
            commandReader: StubProcessCommandReader(commandsByPID: [
                100: "/bin/zsh",
                101: "/opt/homebrew/bin/claude",
            ])
        )

        let paneIDs = resolver.paneIDs(
            records: records,
            worktree: "/repo/.worktrees/alice",
            runtime: .claude,
            paneIDForSessionName: { $0 == "graftty-aaaaaaaa" ? paneID : nil },
            shellPIDForPaneID: { $0 == paneID ? 100 : nil }
        )

        #expect(paneIDs == [paneID])
    }

    private func record(
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: runtime,
            paneSessionName: paneSessionName,
            pid: 999_999,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private struct StubDeliveryProcessTreeWalker: ProcessTreeWalking {
    let descendantsByRoot: [pid_t: [pid_t]]

    func descendants(of root: pid_t) -> [pid_t] {
        descendantsByRoot[root] ?? []
    }

    func descendants(rootedAt roots: [pid_t]) -> [pid_t: [pid_t]] {
        Dictionary(uniqueKeysWithValues: roots.map { ($0, descendantsByRoot[$0] ?? []) })
    }
}

private struct StubProcessCommandReader: ProcessCommandReading {
    let commandsByPID: [pid_t: String]

    func commandLine(pid: pid_t) -> String? {
        commandsByPID[pid]
    }
}

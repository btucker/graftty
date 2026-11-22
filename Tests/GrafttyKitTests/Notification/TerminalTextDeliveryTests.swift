import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct TerminalTextDeliveryTests {
    @Test("@spec WATCH-3.1: When a paired client reads terminal output, the host shall resolve the pane within the requested running worktree and read at most 200 recent lines without sending input, resizing the terminal, or acknowledging attention.")
    func readsOnlyTheRequestedPane() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let first = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        let second = PaneSlotID()
        platform.state.repos[0].worktrees[0].splitTree = platform.state.repos[0].worktrees[0].splitTree.inserting(second, at: first, direction: .horizontal)
        platform.state.repos[0].worktrees[0].ensurePaneSession(for: second)
        let session = ZmxLauncher.sessionName(for: try #require(platform.state.repos[0].worktrees[0].paneSessions[second]))
        platform.platformResponse = .paneShow("one\n  two\n$ ")
        let response = await TerminalTextDelivery.read(worktreeID: "/repo", paneID: session, lines: 500, platform: platform)
        #expect(response == .terminalText("one\n  two\n$ "))
        #expect(platform.platformRequests == [.showPane(path: "/repo", index: 2, lines: 200)])
        #expect(platform.stateChanges == 0)
        let wrongPane = await TerminalTextDelivery.read(worktreeID: "/repo", paneID: "another", lines: 200, platform: platform)
        guard case .error = wrongPane else { Issue.record("Read an unrelated terminal"); return }
        #expect(platform.platformRequests.count == 1)
        platform.state.repos[0].worktrees[0].state = .closed
        guard case .error = await TerminalTextDelivery.read(worktreeID: "/repo", paneID: session, lines: 200, platform: platform) else {
            Issue.record("Read a closed worktree"); return
        }
        #expect(platform.platformRequests.count == 1)
    }

    @Test("@spec WATCH-3.2: If terminal output exceeds the watch text budget, then the host shall retain the newest complete UTF-8 characters within 24000 bytes.")
    func boundsUnicodeOutputAndPreservesItsTail() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.platformResponse = .paneShow(String(repeating: "界", count: 10_000) + "\n$ ")
        let response = await TerminalTextDelivery.read(worktreeID: "/repo", paneID: platform.paneSession, lines: 200, platform: platform)
        guard case .terminalText(let text) = response else { Issue.record("Expected terminal output"); return }
        #expect(text.utf8.count <= 24_000)
        #expect(text.hasSuffix("界\n$ "))
        #expect(!text.contains("�"))
    }

    @Test func terminalRequestsAndResponsesRoundTrip() throws {
        let request = WorktreeManagementRequest.terminalText(worktreeID: "/wt", paneID: "pane", lines: 200)
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONEncoder().encode(request)) == request)
        let response = WorktreeManagementResponse.terminalText("  $ printf hello\nhello")
        #expect(try JSONDecoder().decode(WorktreeManagementResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}

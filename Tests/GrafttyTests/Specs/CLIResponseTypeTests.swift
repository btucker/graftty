import ArgumentParser
import Foundation
import Testing
import GrafttyKit
@testable import GrafttyCLI

@Suite("@spec ATTN-1.29: If the application answers a CLI request that expects a response with a response of a different type, then the CLI shall print `Unexpected <type> response for <command>` naming the wire type it received, and exit with code 1.")
struct CLIResponseTypeTests {
    private static func inboxErrors(
        page: ResponseMessage,
        advance: ResponseMessage = .ok
    ) throws -> [String] {
        let command = try TeamInbox.parse([])
        var errors: [String] = []
        #expect(throws: ExitCode.self) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    if case .teamInboxAdvance = request { return advance }
                    return page
                },
                writeOutput: { _ in },
                writeError: { errors.append($0) }
            )
        }
        return errors
    }

    @Test func wrongPageResponseNamesItsType() throws {
        #expect(try Self.inboxErrors(page: .paneList([])) == ["Unexpected pane_list response for team inbox"])
    }

    @Test func wrongAdvanceResponseNamesItsTypeAfterTheRecoveryHint() throws {
        let message = TeamInboxMessage(
            id: "m1", batchID: nil, createdAt: Date(timeIntervalSince1970: 0), team: "t", repoPath: "/repo",
            from: .init(member: "bob", worktree: "/repo/.worktrees/bob", runtime: nil),
            to: .init(member: "alice", worktree: "/repo/.worktrees/alice", runtime: nil),
            priority: .normal, body: "hi")
        let errors = try Self.inboxErrors(
            page: .teamInbox(messages: [message], nextBeforeID: nil, nextAfterID: nil, snapshotThroughID: "m1"),
            advance: .paneShow("x"))
        #expect(errors.last == "Unexpected pane_show response for team inbox")
        #expect(errors.first?.contains("remain unread") == true)
    }

    @Test func wrongResponseToAnOkCommandNamesItsType() {
        var errors: [String] = []
        #expect(throws: ExitCode.self) {
            try CLIEnv.expectOk(.paneList([]), for: "team send", writeError: { errors.append($0) })
        }
        #expect(errors == ["Unexpected pane_list response for team send"])
    }

    @Test func serverErrorAndBusyKeepTheirOwnText() throws {
        #expect(try Self.inboxErrors(page: .error("lock timeout")) == ["lock timeout"])
        #expect(try Self.inboxErrors(page: .serverBusy) == [ResponseMessage.serverBusyMessage])
    }

    @Test func paneShowAndSendNameTheWrongType() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        let stderr = CapturingTextSink()

        transport.queue = [.ok]
        #expect(PaneShowDispatcher.run(address: "drag-files:1", lines: 10, transport: transport,
                                       stdout: CapturingTextSink(), stderr: stderr, stateDirectory: stateDir) == 1)
        transport.queue = [.paneShow("x")]
        #expect(PaneSendDispatcher.run(address: "drag-files:1", text: "ls", pressEnter: true, transport: transport,
                                       stderr: stderr, stateDirectory: stateDir) == 1)
        transport.queue = [.ok]
        #expect(PaneShowDispatcher.run(address: "drag-files", lines: 10, transport: transport,
                                       stdout: CapturingTextSink(), stderr: stderr, stateDirectory: stateDir) == 1)
        #expect(stderr.text == """
            graftty: Unexpected ok response for pane show
            graftty: Unexpected pane_show response for pane send
            graftty: Unexpected ok response for pane show

            """)
    }
}

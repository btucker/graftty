import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import GrafttyKit

@Suite("graftty team inbox read behavior")
struct TeamInboxReadCLITests {
    private enum OutputFailure: Error { case closed }

    @Test("Default, peek, diagnostic, and history modes parse distinctly")
    func parsesReadModes() throws {
        let consuming = try TeamInbox.parse([])
        try consuming.validate()
        #expect(consuming.readMode == .consumeUnread)

        for arguments in [
            ["--keep-unread"],
            ["--unread"],
            ["--member", "main"],
            ["--worktree", "main"],
            ["--repo", "/repo"],
        ] {
            let peek = try TeamInbox.parse(arguments)
            try peek.validate()
            #expect(peek.readMode == .peekUnread)
        }

        let history = try TeamInbox.parse(["--history"])
        try history.validate()
        #expect(history.readMode == .history)

        #expect(throws: (any Error).self) {
            let conflicting = try TeamInbox.parse(["--history", "--keep-unread"])
            try conflicting.validate()
        }
    }

    @Test("Inbox help makes automatic advancement and peeking explicit")
    func helpDocumentsReadSemantics() {
        let help = TeamInbox.helpMessage()
        #expect(help.contains("marks displayed messages read"))
        #expect(help.contains("--keep-unread"))
        #expect(help.contains("--history"))
        #expect(!Team.helpMessage().contains("  ack"))
    }

    @Test("@spec TEAM-4.8: When `graftty team inbox` displays unread messages for the calling worktree, the application shall advance that worktree's shared delivery watermark through the last displayed row only after stdout accepts the complete output.")
    func consumingReadWritesBeforeAdvancing() throws {
        let messages = [Self.message("m1"), Self.message("m2")]
        let command = try TeamInbox.parse([])
        var events: [String] = []
        var requests: [NotificationMessage] = []

        try command.execute(
            callerWorktree: "/repo/.worktrees/alice",
            callerAgentID: "codex-0123456789ab",
            sendRequest: { request in
                requests.append(request)
                switch request {
                case .teamInbox:
                    events.append("read")
                    return .teamInbox(
                        messages: messages,
                        nextBeforeID: nil,
                        nextAfterID: nil,
                        snapshotThroughID: "m2"
                    )
                case .teamInboxAdvance(_, let callerAgentID, let throughID):
                    #expect(callerAgentID == "codex-0123456789ab")
                    events.append("advance:\(throughID)")
                    return .ok
                default:
                    Issue.record("unexpected request: \(request)")
                    return .error("unexpected")
                }
            },
            writeOutput: { data in
                #expect(String(decoding: data, as: UTF8.self).contains("m2"))
                events.append("write")
            },
            writeError: { _ in }
        )

        #expect(events == ["read", "write", "advance:m2"])
        #expect(requests.count == 2)
    }

    @Test("A failed stdout write leaves the unread prefix unadvanced")
    func failedOutputDoesNotAdvance() throws {
        let command = try TeamInbox.parse([])
        var requests: [NotificationMessage] = []

        #expect(throws: OutputFailure.closed) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    requests.append(request)
                    return .teamInbox(
                        messages: [Self.message("m1")],
                        nextBeforeID: nil,
                        nextAfterID: nil,
                        snapshotThroughID: "m1"
                    )
                },
                writeOutput: { _ in throw OutputFailure.closed },
                writeError: { _ in }
            )
        }

        #expect(requests.count == 1)
    }

    @Test("A consuming read fails closed when an older app returns a row targeted to another runtime.")
    func consumingReadRejectsUnscopedLegacyResponse() throws {
        let command = try TeamInbox.parse([])
        var requests: [NotificationMessage] = []
        var writes = 0
        var errors: [String] = []

        #expect(throws: ExitCode.self) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                callerAgentID: "codex-0123456789ab",
                sendRequest: { request in
                    requests.append(request)
                    return .teamInbox(
                        messages: [Self.message("m1", runtime: "claude")],
                        nextBeforeID: nil,
                        nextAfterID: nil,
                        snapshotThroughID: "m1"
                    )
                },
                writeOutput: { _ in writes += 1 },
                writeError: { errors.append($0) }
            )
        }

        #expect(requests.count == 1)
        #expect(writes == 0)
        #expect(errors.joined().contains("update or restart"))
    }

    @Test("An all-pages read carries a fixed snapshot forward and advances through its last row")
    func allPagesUseOneSnapshotAndAdvanceThroughLastDisplayedRow() throws {
        let command = try TeamInbox.parse(["--all"])
        var requests: [NotificationMessage] = []
        var output = ""

        try command.execute(
            callerWorktree: "/repo/.worktrees/alice",
            sendRequest: { request in
                requests.append(request)
                switch request {
                case .teamInbox(let request)
                    where request.afterID == nil &&
                          request.snapshotThroughID == nil &&
                          request.forwardPagination == true:
                    return .teamInbox(
                        messages: [Self.message("m1"), Self.message("m2")],
                        nextBeforeID: nil,
                        nextAfterID: "m2",
                        snapshotThroughID: "m3"
                    )
                case .teamInbox(let request)
                    where request.afterID == "m2" &&
                          request.snapshotThroughID == "m3" &&
                          request.forwardPagination == true:
                    return .teamInbox(
                        messages: [Self.message("m3")],
                        nextBeforeID: nil,
                        nextAfterID: nil,
                        snapshotThroughID: "m3"
                    )
                case .teamInboxAdvance(_, _, "m3"):
                    return .ok
                default:
                    return .error("unexpected request: \(request)")
                }
            },
            writeOutput: { output = String(decoding: $0, as: UTF8.self) },
            writeError: { _ in }
        )

        #expect(requests.count == 3)
        #expect(output.firstRange(of: "m1")!.lowerBound < output.firstRange(of: "m2")!.lowerBound)
        #expect(output.firstRange(of: "m2")!.lowerBound < output.firstRange(of: "m3")!.lowerBound)
    }

    @Test("@spec TEAM-4.11: When a nonempty unread team inbox response lacks the fixed-snapshot capability, the CLI shall reject it before output or advancement rather than risk misordered or silently truncated delivery.")
    func unreadReadRejectsLegacyBackwardPagedResponse() throws {
        let command = try TeamInbox.parse(["--all"])
        var outputWrites = 0
        var requests: [NotificationMessage] = []

        #expect(throws: ExitCode.self) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    requests.append(request)
                    switch request {
                    case .teamInbox:
                        return .teamInbox(
                            messages: [Self.message("m1")],
                            nextBeforeID: "m1",
                            nextAfterID: nil,
                            snapshotThroughID: nil
                        )
                    case .teamInboxAdvance:
                        return .ok
                    default:
                        return .error("unexpected")
                    }
                },
                writeOutput: { _ in outputWrites += 1 },
                writeError: { _ in }
            )
        }

        #expect(requests.count == 1)
        #expect(outputWrites == 0)
    }

    @Test("@spec TEAM-4.9: When a team inbox read uses `--keep-unread`, its `--unread` alias, or a diagnostic selector, the application shall leave delivery state unchanged and explain on stderr how the target worktree can perform a consuming read.")
    func peekReadsDoNotAdvanceAndExplainRecovery() throws {
        for arguments in [
            ["--keep-unread"],
            ["--unread"],
            ["--member", "main"],
            ["--history", "--member", "main"],
        ] {
            let command = try TeamInbox.parse(arguments)
            var requests: [NotificationMessage] = []
            var errors: [String] = []
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    requests.append(request)
                    return .teamInbox(
                        messages: [Self.message("m1")],
                        nextBeforeID: nil,
                        nextAfterID: nil,
                        snapshotThroughID: "m1"
                    )
                },
                writeOutput: { _ in },
                writeError: { errors.append($0) }
            )

            #expect(requests.count == 1)
            #expect(errors.joined().contains("run `graftty team inbox`"))
            #expect(errors.joined().contains("Do not edit Graftty state files"))
        }
    }

    @Test("An advancement failure directs the agent to rerun the supported command")
    func advancementFailureExplainsSupportedRecovery() throws {
        let command = try TeamInbox.parse([])
        var errors: [String] = []

        #expect(throws: ExitCode.self) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    switch request {
                    case .teamInbox:
                        return .teamInbox(
                            messages: [Self.message("m1")],
                            nextBeforeID: nil,
                            nextAfterID: nil,
                            snapshotThroughID: "m1"
                        )
                    case .teamInboxAdvance:
                        return .error("lock timeout")
                    default:
                        return .error("unexpected")
                    }
                },
                writeOutput: { _ in },
                writeError: { errors.append($0) }
            )
        }

        let error = errors.joined(separator: "\n")
        #expect(error.contains("remain unread"))
        #expect(error.contains("rerun `graftty team inbox`"))
        #expect(error.contains("Do not edit Graftty state files"))
    }

    @Test("A transport failure while advancing emits the same supported recovery")
    func advancementTransportFailureExplainsSupportedRecovery() throws {
        let command = try TeamInbox.parse([])
        var errors: [String] = []

        #expect(throws: ExitCode.self) {
            try command.execute(
                callerWorktree: "/repo/.worktrees/alice",
                sendRequest: { request in
                    switch request {
                    case .teamInbox:
                        return .teamInbox(
                            messages: [Self.message("m1")],
                            nextBeforeID: nil,
                            nextAfterID: nil,
                            snapshotThroughID: "m1"
                        )
                    case .teamInboxAdvance:
                        throw OutputFailure.closed
                    default:
                        return .error("unexpected")
                    }
                },
                writeOutput: { _ in },
                writeError: { errors.append($0) }
            )
        }

        let error = errors.joined(separator: "\n")
        #expect(error.contains("remain unread"))
        #expect(error.contains("rerun `graftty team inbox`"))
    }

    private static func message(_ id: String, runtime: String? = nil) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id,
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            team: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(
                member: "alice",
                worktree: "/repo/.worktrees/alice",
                runtime: runtime
            ),
            priority: .normal,
            body: id
        )
    }
}

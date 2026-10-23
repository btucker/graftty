import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import enum GrafttyKit.NotificationMessage
import enum GrafttyKit.ResponseMessage

@Suite("Control socket permission failures")
struct SocketClientPermissionTests {
    @Test(arguments: [EPERM, EACCES])
    func denialExplainsPathErrnoAndSandboxPolicy(errno: Int32) {
        let description = CLIError.socketPermissionDenied(path: "/tmp/graftty.sock", errno: errno).description
        #expect(description.contains("/tmp/graftty.sock"))
        #expect(description.contains("errno \(errno)"))
        #expect(description.contains("sandbox policy or filesystem permissions"))
        #expect(description.contains("narrowly scoped permission"))
        #expect(!description.contains("relaunch"))
    }

    @Test func denialIsNotRetriedByEitherTransport() throws {
        let denied = CLIError.socketPermissionDenied(path: "/tmp/s", errno: EPERM)
        var attempts = 0
        let operation: (NotificationMessage) throws -> ResponseMessage = { _ in
            attempts += 1
            throw denied
        }
        let message = NotificationMessage.teamList(callerWorktree: "/tmp/wt")
        #expect(throws: CLIError.self) {
            try SocketClient.send(message, sleep: { _ in Issue.record("Unexpected retry") }, operation: operation)
        }
        #expect(attempts == 1)
        #expect(throws: CLIError.self) {
            _ = try SocketClient.sendExpectingResponse(message, sleep: { _ in Issue.record("Unexpected retry") }, operation: operation)
        }
        #expect(attempts == 2)
    }

    @Test func worktreeWaitsReportDenialWithoutPolling() throws {
        let denied = CLIError.socketPermissionDenied(path: "/tmp/s", errno: EPERM)
        let command = try WorktreeAdd.parse(["probe"])
        let create = command.creationRequest(
            callerWorktree: "/tmp/wt", names: (worktree: "probe", branch: "probe"),
            agentRuntime: nil, resolvedPrompt: nil, operationID: "probe"
        )
        var attempts = 0
        var errors: [String] = []
        #expect(throws: ExitCode.self) {
            _ = try WorktreeAdd.sendRequestRetryingTimeout(
                create,
                operationID: "probe",
                deadline: Date().addingTimeInterval(60),
                send: { _ in attempts += 1; throw denied },
                sleep: { _ in Issue.record("Unexpected retry") },
                writeError: { errors.append($0) }
            )
        }
        #expect(attempts == 1)
        #expect(errors == [denied.description])

        #expect(throws: ExitCode.self) {
            try CapabilityProbe.require(
                [.worktreeCreateIdempotency],
                retryTransportFailuresUntil: Date().addingTimeInterval(60),
                send: { _ in attempts += 1; throw denied },
                sleep: { _ in Issue.record("Unexpected retry") }
            )
        }
        #expect(attempts == 2)
    }

    @Test(arguments: [false, true])
    func denialPreservesPotentiallyAcceptedCreation(timedOut: Bool) throws {
        let denied = CLIError.socketPermissionDenied(path: "/tmp/s", errno: EPERM)
        let command = try WorktreeAdd.parse(["probe"])
        let request = timedOut ? command.creationRequest(
            callerWorktree: "/tmp/wt", names: (worktree: "probe", branch: "probe"),
            agentRuntime: nil, resolvedPrompt: nil, operationID: "probe"
        ) : .worktreeCreateStatus(operationID: "probe")
        var attempts = 0
        var sleeps = 0
        var errors: [String] = []
        #expect(throws: ExitCode.self) {
            _ = try WorktreeAdd.sendRequestRetryingTimeout(
                request, operationID: "probe", deadline: Date().addingTimeInterval(60),
                send: { _ in
                    attempts += 1
                    if timedOut && attempts == 1 { throw CLIError.socketTimeout }
                    throw denied
                },
                sleep: { _ in sleeps += 1 },
                writeError: { errors.append($0) }
            )
        }
        #expect(attempts == (timedOut ? 2 : 1))
        #expect(sleeps == (timedOut ? 1 : 0))
        #expect(errors == [denied.description, "worktree creation operation probe may still finish"])
    }
}

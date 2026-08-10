import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import enum GrafttyKit.ResponseMessage
import enum GrafttyKit.SocketIO

@Suite("""
@spec ATTN-3.7: When the application rejects a control-socket request with its structured busy response before dispatching the request, the CLI shall retry the request with bounded backoff before reporting the saturation error.
""")
struct SocketClientBusyRetryTests {
    @Test func retriesBusyResponsesUntilRequestSucceeds() {
        var attempts = 0
        var sleeps: [TimeInterval] = []

        let response = SocketClient.retryingServerBusy(
            delays: [0.01, 0.02, 0.03],
            sleep: { sleeps.append($0) }
        ) {
            attempts += 1
            return attempts < 3
                ? .serverBusy
                : .ok
        }

        #expect(response == .ok)
        #expect(attempts == 3)
        #expect(sleeps == [0.01, 0.02])
    }

    @Test func returnsBusyAfterBoundedRetriesAreExhausted() {
        var attempts = 0
        var sleeps = 0

        let response = SocketClient.retryingServerBusy(
            delays: [0, 0],
            sleep: { _ in sleeps += 1 }
        ) {
            attempts += 1
            return .serverBusy
        }

        #expect(response == .serverBusy)
        #expect(attempts == 3)
        #expect(sleeps == 2)
    }

    @Test func oneWayMessagesAwaitAdmissionAndRetryBusyRejections() throws {
        var attempts = 0
        var sleeps: [TimeInterval] = []
        try SocketClient.send(
            .notify(
                path: "/tmp/wt",
                text: "hi",
                clearAfter: nil,
                paneSessionName: nil
            ),
            delays: [0.01],
            sleep: { sleeps.append($0) },
            operation: { _ in
                attempts += 1
                return attempts == 1
                    ? .serverBusy
                    : .ok
            }
        )

        #expect(attempts == 2)
        #expect(sleeps == [0.01])
    }

    @Test func oneWayTimeoutAfterSuccessfulWritePreservesLegacySuccess() throws {
        let response = try SocketClient.resolveOneWayResult(
            writeFailure: nil,
            read: SocketIO.CappedRead(
                data: Data(),
                exceededCap: false,
                readError: EAGAIN
            )
        )

        #expect(response == .ok)
        #expect(SocketClient.oneWayAdmissionTimeoutSeconds == 2)
    }

    @Test func exhaustedBusyRetriesReachBothCLITransportPaths() {
        for operation in [
            {
                try SocketClient.send(
                    .notify(path: "/tmp/wt", text: "hi"),
                    delays: [],
                    sleep: { _ in },
                    operation: { _ in .serverBusy }
                )
            },
            {
                _ = try SocketClient.sendExpectingResponse(
                    .teamList(callerWorktree: "/tmp/wt"),
                    delays: [],
                    sleep: { _ in },
                    operation: { _ in .serverBusy }
                )
            },
        ] {
            do {
                try operation()
                Issue.record("Expected socketBusy")
            } catch let error as CLIError {
                guard case .socketBusy = error else {
                    Issue.record("Expected socketBusy, got \(error)")
                    continue
                }
                #expect(error.description == ResponseMessage.serverBusyMessage)
            } catch {
                Issue.record("Expected socketBusy, got \(error)")
            }
        }

        var errors: [String] = []
        #expect(throws: ExitCode.self) {
            _ = try CLIEnv.sendRequest(
                .teamList(callerWorktree: "/tmp/wt"),
                using: { _ in throw CLIError.socketBusy },
                writeError: { errors.append($0) }
            )
        }
        #expect(errors == [ResponseMessage.serverBusyMessage])
    }

    @Test func busyWireResponseIsMachineReadableAndLegacyFriendly() throws {
        let data = try JSONEncoder().encode(ResponseMessage.serverBusy)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(object["type"] == "error")
        #expect(object["message"] == ResponseMessage.serverBusyMessage)
        #expect(object["code"] == ResponseMessage.serverBusyCode)
        #expect(try JSONDecoder().decode(ResponseMessage.self, from: data) == .serverBusy)
        #expect(try JSONDecoder().decode(
            ResponseMessage.self,
            from: Data(#"{"type":"error","message":"graftty.control-socket.busy.v1"}"#.utf8)
        ) == .serverBusy)
    }
}

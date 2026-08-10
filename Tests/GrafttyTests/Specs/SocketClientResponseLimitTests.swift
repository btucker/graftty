import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import class GrafttyKit.SocketServer
import enum GrafttyKit.SocketIO

@Suite("SocketClient response limits")
struct SocketClientResponseLimitTests {
    @Test func productionResponseLimitIsSixteenMiB() {
        #expect(SocketClient.maxResponseBytes == 16 * 1024 * 1024)
    }

    @Test func oversizedReadMapsToSpecificCLIErrorBeforeDecoding() {
        do {
            _ = try SocketClient.decodeResponse(
                SocketIO.CappedRead(data: Data("partial json".utf8), exceededCap: true)
            )
            Issue.record("Expected responseTooLarge")
        } catch let error as CLIError {
            if case .responseTooLarge(let maxBytes) = error {
                #expect(maxBytes == SocketClient.maxResponseBytes)
            } else {
                Issue.record("Expected responseTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }

    @Test("""
    @spec ATTN-3.3: If the control socket remains unresponsive through the application's five-second request-handler deadline, then the CLI shall wait one additional second for response-or-close propagation before printing a six-second timeout error and exiting with code 1.
    """)
    func readDeadlineMapsToTimeout() {
        #expect(
            SocketClient.socketTimeoutSeconds
                == SocketServer.defaultRequestTimeoutSeconds + 1
        )
        #expect(SocketClient.socketTimeoutSeconds == 6)
        #expect(SocketClient.socketSendTimeoutSeconds == 2)
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        #expect(SocketClient.configureSocket(sockets[0]))
        var productionSendTimeout = timeval()
        var productionSendTimeoutSize = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_SNDTIMEO,
            &productionSendTimeout,
            &productionSendTimeoutSize
        ) == 0)
        #expect(productionSendTimeout.tv_sec == 2)
        var productionReceiveTimeout = timeval()
        var productionReceiveTimeoutSize = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_RCVTIMEO,
            &productionReceiveTimeout,
            &productionReceiveTimeoutSize
        ) == 0)
        #expect(productionReceiveTimeout.tv_sec == 6)

        #expect(SocketClient.configureSocket(
            sockets[0],
            sendTimeoutSeconds: 1,
            receiveTimeoutSeconds: 1
        ))
        var receiveTimeout = timeval()
        var receiveTimeoutSize = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            &receiveTimeoutSize
        ) == 0)
        #expect(receiveTimeout.tv_sec == 1)

        let timedOutRead = SocketIO.readCapped(
            fd: sockets[0],
            cap: SocketClient.maxResponseBytes
        )
        #expect(timedOutRead.data.isEmpty)
        #expect(
            timedOutRead.readError == EAGAIN
                || timedOutRead.readError == EWOULDBLOCK
        )
        do {
            _ = try SocketClient.decodeResponse(timedOutRead)
            Issue.record("Expected socketTimeout")
        } catch let error as CLIError {
            guard case .socketTimeout = error else {
                Issue.record("Expected socketTimeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected socketTimeout, got \(error)")
        }

        var errors: [String] = []
        do {
            _ = try CLIEnv.sendRequest(
                .teamList(callerWorktree: "/tmp/wt"),
                using: { _ in throw CLIError.socketTimeout },
                writeError: { errors.append($0) }
            )
            Issue.record("Expected ExitCode(1)")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 1)
        } catch {
            Issue.record("Expected ExitCode(1), got \(error)")
        }
        #expect(errors == ["Connection timed out after 6 seconds"])
    }

    @Test("""
    @spec ATTN-3.8: When the application closes a control-socket request without a response before the receive deadline, the CLI shall report the premature close rather than claim that the full receive deadline elapsed.
    """)
    func immediateEOFIsNotMisreportedAsTimeout() {
        do {
            _ = try SocketClient.decodeResponse(
                SocketIO.CappedRead(
                    data: Data(),
                    exceededCap: false,
                    readError: nil
                )
            )
            Issue.record("Expected socketClosedWithoutResponse")
        } catch let error as CLIError {
            guard case .socketClosedWithoutResponse = error else {
                Issue.record(
                    "Expected socketClosedWithoutResponse, got \(error)"
                )
                return
            }
            #expect(
                error.description
                    == "Graftty closed the control connection without a response"
            )
        } catch {
            Issue.record("Expected socketClosedWithoutResponse, got \(error)")
        }
    }
}

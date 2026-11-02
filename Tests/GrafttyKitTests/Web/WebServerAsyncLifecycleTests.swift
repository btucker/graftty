import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import GrafttyKit

@Suite("@spec WEB-1.18: When Web Access starts or stops a listener, the application shall await NIO lifecycle completion without blocking the main actor, close every partial bind on failure or cancellation, and allow the released port to be bound again.")
@MainActor
struct WebServerAsyncLifecycleTests {
    private func makeServer(port: Int = 0, addresses: [String] = ["127.0.0.1"]) throws -> WebServer {
        WebServer(
            config: .init(port: port, zmxExecutable: URL(fileURLWithPath: "/dev/null"), zmxDir: URL(fileURLWithPath: "/tmp")),
            auth: .init(isAllowed: { _ in true }),
            bindAddresses: addresses,
            tlsProvider: try makeTestTLSProvider()
        )
    }

    @Test func startSuspendsWhileBindIsPendingAndCancellationCleansUp() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let entered = loop.makePromise(of: Void.self)
        let gate = loop.makePromise(of: Void.self)
        let server = try makeServer()
        server.beforeBindForTests = {
            entered.succeed(())
            return gate.futureResult
        }
        let start = Task { try await server.startAsync() }
        try await entered.futureResult.get()
        // This line runs on the main actor while bind is still gated.
        #expect(server.status == .stopped)
        start.cancel()
        gate.succeed(())
        do {
            try await start.value
            Issue.record("cancelled startup succeeded")
        } catch { #expect(error is CancellationError) }
        #expect(server.status == .stopped)
        server.beforeBindForTests = nil
        try await server.startAsync()
        #expect({ if case .listening = server.status { true } else { false } }())
        await server.stopAsync()
    }

    @Test func laterBindFailureClosesEarlierListenerAndPreservesError() async throws {
        let reservation = try makeServer()
        try await reservation.startAsync()
        guard case let .listening(_, port) = reservation.status else {
            Issue.record("reservation did not bind")
            return
        }
        await reservation.stopAsync()
        // The first address binds; the second intentionally conflicts with it.
        let partial = try makeServer(port: port, addresses: ["127.0.0.1", "127.0.0.1"])
        do {
            try await partial.startAsync()
            Issue.record("duplicate fixed-port bind unexpectedly succeeded")
        } catch { #expect(WebServer.isAddressInUse(error)) }
        #expect(partial.status == .portUnavailable)
        let replacement = try makeServer(port: port)
        try await replacement.startAsync()
        await replacement.stopAsync()
        // Repeated cleanup also completes and must not erase a newer listener.
        await replacement.stopAsync()
    }

    @Test func stopSuspendsUntilEventLoopsFinish() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let entered = loop.makePromise(of: Void.self)
        let release = loop.makePromise(of: Void.self)
        let server = try makeServer()
        try await server.startAsync()
        server.shutdownForTests = { group, completion in
            entered.succeed(())
            release.futureResult.whenSuccess { group.shutdownGracefully(completion) }
        }
        let stop = Task { await server.stopAsync() }
        try await entered.futureResult.get()
        // A main-actor test reaches this assertion before shutdown is released.
        release.succeed(())
        await stop.value
        #expect(server.status == .stopped)
        server.shutdownForTests = nil
        try await server.startAsync()
        await server.stopAsync()
    }
}

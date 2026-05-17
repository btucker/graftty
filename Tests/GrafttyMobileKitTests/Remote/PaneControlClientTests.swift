#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("PaneControlClient — round-trips split/close/swap RPCs against a server-side echo handler.")
struct PaneControlClientTests {

    @Test
    func splitRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.split(target: "session-a", direction: .horizontal)
        #expect(response == .ok)
    }

    @Test
    func closeRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.close(target: "session-b")
        #expect(response == .ok)
    }

    @Test
    func swapRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.swap(source: "session-a", target: "session-c")
        #expect(response == .ok)
    }

    @Test
    func errorResponsePassesThrough() async throws {
        let env = try await loopback { _ in
            .error(code: "conflict", message: "concurrent split rejected")
        }
        let response = try await env.client.split(target: "session-a", direction: .vertical)
        #expect(response == .error(code: "conflict", message: "concurrent split rejected"))
    }

    private struct Env {
        let client: PaneControlClient
    }

    private func loopback(
        mutator: @escaping @Sendable (PaneControlRequest) async -> PaneControlResponse
    ) async throws -> Env {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        await serverRouter.register(type: "pane_control") {
            PaneControlHandlerProxy(mutator: mutator)
        }

        let client = PaneControlClient(router: mobileRouter)
        try await client.open()
        // Allow the open frame to ride across before the first RPC.
        try await Task.sleep(for: .milliseconds(50))
        return Env(client: client)
    }
}

/// In-test analogue of `PaneControlHandler` — same logic, but defined
/// here so the mobile-side test target doesn't need to import GrafttyKit
/// (it can't, target boundary).
private actor PaneControlHandlerProxy: ChannelHandler {
    nonisolated let channelType = "pane_control"
    private let mutator: @Sendable (PaneControlRequest) async -> PaneControlResponse
    private var outbox: ChannelOutbox?
    private var id: ChannelID?

    init(mutator: @escaping @Sendable (PaneControlRequest) async -> PaneControlResponse) {
        self.mutator = mutator
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.id = id
    }

    func onPayload(_ data: Data) async {
        guard let outbox, let id else { return }
        let request: PaneControlRequest
        do {
            request = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        } catch {
            let body = try? JSONEncoder().encode(
                PaneControlResponse.error(code: "malformed-request", message: String(describing: error))
            )
            if let body { try? await outbox.send(.payload(ChannelPayload(id: id), body)) }
            return
        }
        let response = await mutator(request)
        guard let body = try? JSONEncoder().encode(response) else { return }
        try? await outbox.send(.payload(ChannelPayload(id: id), body))
    }

    func onClose() async {}
    func onError(_ code: String, message: String) async {}
}

private final class FakePair: Sendable {
    let aliceSide: AliceTransport
    let bobSide: BobTransport
    init() {
        let aliceToBob = FakeBridge()
        let bobToAlice = FakeBridge()
        self.aliceSide = AliceTransport(out: aliceToBob, in: bobToAlice)
        self.bobSide = BobTransport(out: bobToAlice, in: aliceToBob)
    }
}

private actor FakeBridge {
    var subscriber: (@Sendable (Data) async -> Void)?
    func subscribe(_ s: @escaping @Sendable (Data) async -> Void) { subscriber = s }
    func publish(_ data: Data) async { await subscriber?(data) }
}

private struct AliceTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct BobTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}
#endif

#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `pane_control` channel. Opens a single
/// pane_control channel on construction and exposes typed RPC methods
/// (`split`, `close`, `swap`). Each RPC awaits its response over the
/// channel before returning.
public actor PaneControlClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
        case unexpectedFrame
    }

    private let router: ChannelRouter
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?
    private var pendingResponse: CheckedContinuation<PaneControlResponse, Error>?

    public init(router: ChannelRouter) {
        self.router = router
    }

    public func open() async throws {
        let handler = ResponseHandler(
            onOutbox: { [weak self] outbox in
                await self?.captureOutbox(outbox)
            },
            onResponse: { [weak self] response in
                await self?.deliverResponse(response)
            }
        )
        let id = try await router.open(type: "pane_control", handler: handler)
        self.channelID = id
    }

    public func close() async {
        guard let id = channelID else { return }
        channelID = nil
        try? await router.close(id)
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await sendAndAwait(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await sendAndAwait(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await sendAndAwait(.swap(source: source, target: target))
    }

    private func sendAndAwait(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        guard let outbox, let channelID else { throw ClientError.notOpen }
        let body = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PaneControlResponse, Error>) in
            self.pendingResponse = continuation
            Task {
                do {
                    try await outbox.send(.payload(ChannelPayload(id: channelID), body))
                } catch {
                    let c = pendingResponse
                    pendingResponse = nil
                    c?.resume(throwing: error)
                }
            }
        }
    }

    private func deliverResponse(_ response: PaneControlResponse) {
        let c = pendingResponse
        pendingResponse = nil
        c?.resume(returning: response)
    }

    func captureOutbox(_ outbox: ChannelOutbox) {
        self.outbox = outbox
    }
}

/// Handler stored on the `pane_control` channel. Captures the outbox at
/// open time so the client can send subsequent RPCs without going
/// through `router.open()` again, and forwards payload frames as
/// responses to the awaiting continuation.
private actor ResponseHandler: ChannelHandler {
    nonisolated let channelType = "pane_control"

    private let onOutbox: @Sendable (ChannelOutbox) async -> Void
    private let onResponse: @Sendable (PaneControlResponse) async -> Void

    init(
        onOutbox: @escaping @Sendable (ChannelOutbox) async -> Void,
        onResponse: @escaping @Sendable (PaneControlResponse) async -> Void
    ) {
        self.onOutbox = onOutbox
        self.onResponse = onResponse
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        await onOutbox(outbox)
    }

    func onPayload(_ data: Data) async {
        let response: PaneControlResponse
        do {
            response = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        } catch {
            response = .error(code: "malformed-response", message: String(describing: error))
        }
        await onResponse(response)
    }

    func onClose() async {
        await onResponse(.error(
            code: "channel-closed",
            message: "pane_control channel closed before response"
        ))
    }

    func onError(_ code: String, message: String) async {
        await onResponse(.error(code: code, message: message))
    }
}
#endif

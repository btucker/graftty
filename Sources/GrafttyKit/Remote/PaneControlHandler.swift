import Foundation
import GrafttyProtocol

/// @spec REMOTE-7.5
/// `PaneControlHandler` has no reference to `AppState`; per-client focus sovereignty is enforced by construction.
public actor PaneControlHandler: ChannelHandler {
    public nonisolated let channelType = "pane_control"

    public typealias Mutator = @Sendable (PaneControlRequest) async -> PaneControlResponse

    private let mutator: Mutator
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.channelID = id
    }

    public func onPayload(_ data: Data) async {
        guard let outbox, let channelID else { return }
        let request: PaneControlRequest
        do {
            request = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        } catch {
            await reply(
                outbox: outbox,
                channelID: channelID,
                response: .error(
                    code: "malformed-request",
                    message: String(describing: error)
                )
            )
            return
        }
        let response = await mutator(request)
        await reply(outbox: outbox, channelID: channelID, response: response)
    }

    public func onClose() async {
        teardown()
    }

    public func onError(_ code: String, message: String) async {
        teardown()
    }

    private func teardown() {
        outbox = nil
        channelID = nil
    }

    private func reply(
        outbox: ChannelOutbox,
        channelID: ChannelID,
        response: PaneControlResponse
    ) async {
        let body: Data
        do {
            body = try JSONEncoder().encode(response)
        } catch {
            return
        }
        try? await outbox.send(.payload(ChannelPayload(id: channelID), body))
    }
}

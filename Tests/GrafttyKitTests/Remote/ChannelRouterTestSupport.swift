import Foundation
import GrafttyProtocol
@testable import GrafttyKit

/// Generic `ChannelHandler` that records `onOpen`/`onPayload`/`onClose`/`onError`
/// invocations. Shared between `ChannelRouterTests` (two-router bridge tests)
/// and `ChannelRouterOpenCleanupTests` (single-router failure tests).
actor RecordingHandler: ChannelHandler {
    nonisolated let channelType: String
    var opened = false
    var closed = false
    var lastPayload: Data?
    var lastErrorCode: String?
    var outbox: ChannelOutbox?

    init(channelType: String) {
        self.channelType = channelType
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.opened = true
        self.outbox = outbox
    }

    func onPayload(_ data: Data) async {
        self.lastPayload = data
    }

    func onClose() async {
        self.closed = true
    }

    func onError(_ code: String, message: String) async {
        self.lastErrorCode = code
    }
}

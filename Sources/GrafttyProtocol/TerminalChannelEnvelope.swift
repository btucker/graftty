import Foundation

/// JSON shape carried in `ChannelOpen.metadata` for `channel_type:
/// "terminal"`. Identifies the zmx session the channel should attach
/// to. The session name is the same one used by `/sessions` and the
/// existing `/ws?session=` endpoint.
public struct TerminalChannelOpenMeta: Codable, Sendable, Equatable {
    public let sessionName: String
    public init(sessionName: String) {
        self.sessionName = sessionName
    }
}

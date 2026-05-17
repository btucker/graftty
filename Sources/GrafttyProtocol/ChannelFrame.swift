import Foundation

/// Wire-level frame type tag. Each value's metadata shape is the
/// corresponding `Channel*` struct below.
public enum FrameType: UInt8, Sendable, CaseIterable {
    case open    = 0x01
    case close   = 0x02
    case payload = 0x03
    case error   = 0x04
}

/// `open` frame metadata. Opens a new channel of the given type. The
/// receiver's `ChannelRouter` looks up a handler factory by `type`; if
/// found, the handler accepts the open and begins receiving subsequent
/// `payload` frames on this `id`. If no handler factory matches, the
/// router responds with an `error` frame and the channel is dropped.
public struct ChannelOpen: Codable, Sendable, Equatable {
    public let id: ChannelID
    public let type: String
    public init(id: ChannelID, type: String) {
        self.id = id
        self.type = type
    }
}

/// `close` frame metadata. Either side can close. The receiver removes
/// its routing entry and notifies the handler.
public struct ChannelClose: Codable, Sendable, Equatable {
    public let id: ChannelID
    public init(id: ChannelID) { self.id = id }
}

/// `payload` frame metadata. The opaque bytes ride alongside in the
/// frame's payload section (not encoded in this struct).
public struct ChannelPayload: Codable, Sendable, Equatable {
    public let id: ChannelID
    public init(id: ChannelID) { self.id = id }
}

/// `error` frame metadata. Sent by either side to signal a non-recoverable
/// failure on a specific channel. The recipient should drop the channel.
public struct ChannelError: Codable, Sendable, Equatable {
    public let id: ChannelID
    public let code: String
    public let message: String
    public init(id: ChannelID, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }
}

/// Tagged-union aggregate; `ChannelFrameCoder` encodes/decodes this.
public enum ChannelFrame: Sendable, Equatable {
    case open(ChannelOpen)
    case close(ChannelClose)
    case payload(ChannelPayload, Data)
    case error(ChannelError)
}

import Foundation

/// Unique-per-connection identifier for a logical channel multiplexed over
/// the WebRTC DataChannel. Wraps `UInt32` to make routing-by-id a typed
/// operation rather than a raw-integer footgun.
///
/// `ChannelID(0)` is reserved for the channel layer itself (heartbeats,
/// future control messages); concrete channel handlers must use values
/// `>= 1`. The allocator (`ChannelRouter.nextOutboundID`) starts at 1.
public struct ChannelID: Sendable, Hashable, Codable {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public static let reserved = ChannelID(0)
}

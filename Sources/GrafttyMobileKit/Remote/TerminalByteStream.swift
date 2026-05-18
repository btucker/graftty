#if canImport(UIKit)
import Foundation

/// Duplex byte stream for a single terminal session on the mobile side.
/// Currently used by `TerminalChannelClient`'s outbound-bytes path; the
/// inbound bytes flow through the channel framing into a higher-level
/// consumer (eventually `InMemoryTerminalSession`).
///
/// Mirror of the Mac-side `TerminalByteStream` protocol. Forced cross-
/// target duplication: `GrafttyMobileKit` cannot import `GrafttyKit`.
public protocol TerminalByteStream: Sendable {
    func send(_ bytes: Data) async throws
    var inboundBytes: AsyncStream<Data> { get }
    func close() async
}

public typealias TerminalByteStreamFactory = @Sendable (String) async throws -> TerminalByteStream
#endif

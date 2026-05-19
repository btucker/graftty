import Foundation

/// Duplex byte stream for a single terminal session. The Mac-side
/// `TerminalChannelHandler` opens one of these per accepted `terminal`
/// channel via an injected `Factory` callback. Production wires
/// `Factory` to `zmx attach`; tests pass a fake.
public protocol TerminalByteStream: Sendable {
    /// Send bytes to the underlying PTY (keystrokes from the remote
    /// client).
    func send(_ bytes: Data) async throws

    /// Stream of bytes from the underlying PTY (terminal output).
    /// Terminates when the PTY closes.
    var inboundBytes: AsyncStream<Data> { get }

    /// Stop the stream and release any underlying resources (e.g.
    /// terminate the zmx attach process). Conformers **must** finish
    /// the `inboundBytes` `AsyncStream` continuation before returning —
    /// `TerminalChannelHandler.teardown` relies on this to exit its
    /// `for await` loop and reclaim the outbound forwarding task.
    /// A conformer that releases resources without calling
    /// `continuation.finish()` synchronously will leak that task.
    func close() async
}

/// Factory the channel handler uses to obtain a stream for a given
/// session name.
public typealias TerminalByteStreamFactory = @Sendable (String) async throws -> TerminalByteStream

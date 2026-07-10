import Foundation

/// Duplex byte stream for a single terminal session on the client side.
///
/// Mirror of the Mac-side `TerminalByteStream` protocol. Forced cross-
/// target duplication: `GrafttyRemoteClient` cannot import `GrafttyKit`.
public protocol TerminalByteStream: Sendable {
    func send(_ bytes: Data) async throws
    var inboundBytes: AsyncStream<Data> { get }

    /// Stop the stream and release any underlying resources (e.g.
    /// terminate the zmx attach process). Conformers **must** finish
    /// the `inboundBytes` `AsyncStream` continuation before returning —
    /// callers rely on this to exit their `for await` loop and reclaim
    /// the outbound forwarding task. A conformer that releases
    /// resources without calling `continuation.finish()` synchronously
    /// will leak that task.
    func close() async

    /// Adjust the underlying PTY's window size. Default implementation
    /// is a no-op so existing conformers don't break; the production
    /// `zmx attach` Process conformer overrides this to invoke
    /// `ioctl(TIOCSWINSZ, ...)` (or equivalent).
    func resize(cols: Int, rows: Int) async
}

public extension TerminalByteStream {
    func resize(cols: Int, rows: Int) async {}
}

public typealias TerminalByteStreamFactory = @Sendable (String) async throws -> TerminalByteStream

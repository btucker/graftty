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

    /// Adjust the underlying PTY's window size. Default implementation
    /// is a no-op so existing conformers don't break; the production
    /// `zmx attach` Process conformer overrides this to invoke
    /// `ioctl(TIOCSWINSZ, ...)` (or equivalent).
    func resize(cols: Int, rows: Int) async
}

public extension TerminalByteStream {
    func resize(cols: Int, rows: Int) async {}
}

/// Factory the channel handler uses to obtain a stream for a given
/// session name.
public typealias TerminalByteStreamFactory = @Sendable (String) async throws -> TerminalByteStream

/// Optional capability a `TerminalByteStream` conformer can add: reporting
/// live PTY-size changes. Not folded into `TerminalByteStream` itself
/// because most conformers (test fakes, non-PTY-backed streams) have no
/// notion of size events and would otherwise all need to carry a dead
/// stored property. Consumers that care (e.g. `TerminalSessionHandler`,
/// REMOTE-9.4) probe for conformance with `as?` instead of requiring it
/// on every `TerminalByteStream`.
public protocol TerminalSizeReporting: AnyObject {
    /// Invoked whenever the underlying PTY's size changes (and, for
    /// `ZmxAttachEngine`, once more on initial attach). May be called
    /// off the caller's thread — implementations document their own
    /// threading contract. Setting to `nil` removes any installed callback.
    var onPTYSize: ((_ cols: UInt16, _ rows: UInt16) -> Void)? { get set }
}

/// Optional capability a `TerminalByteStream` conformer can add: a
/// **synchronous** resize, alongside `TerminalByteStream.resize(cols:rows:)`'s
/// `async` signature. `TerminalSessionHandler`'s owner-gated resize seam
/// runs entirely on the SSH channel's event loop, and previously wrapped
/// every `resize` in its own unstructured `Task` to call the protocol's
/// async method — with no ordering guarantee between that `Task` and a
/// concurrently-queued PTY write (the exact FIFO hazard
/// `TerminalSessionHandler.ptyWriteContinuation`'s doc comment describes
/// for writes). A conformer whose resize is inherently synchronous
/// (`ZmxAttachEngine`'s `ioctl(TIOCSWINSZ)`) implements this so a caller
/// already on the right thread can invoke it directly, closing that
/// window. Probed for with `as?`, mirroring `TerminalSizeReporting` —
/// conformers/test fakes that only implement the protocol's `async`
/// resize keep working via the existing `Task`-wrapped fallback.
public protocol TerminalSyncResizing: AnyObject {
    func resize(cols: UInt16, rows: UInt16)
}

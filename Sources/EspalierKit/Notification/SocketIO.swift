import Foundation
import Darwin

/// Loop-and-retry write helper for the Unix-domain control socket.
///
/// The naive one-shot form `_ = Darwin.write(fd, buf, count)` was in
/// use at `SocketClient.writeMessage` (CLI side) and at
/// `SocketServer.handleClient`'s response-write site (server side).
/// Two silent-failure classes slipped through:
///
/// 1. **Partial writes.** `write(2)` may return fewer bytes than
///    requested if the kernel's send buffer can't absorb the full
///    payload in one pass. The rest of the payload was silently
///    dropped; the server saw truncated JSON and failed to decode,
///    the CLI saw an empty response and (pre-cycle-138) reported
///    "Empty response from app".
/// 2. **Error returns.** `write` returns -1 with errno on broken
///    pipe / connection reset / any other error. The old call sites
///    did `_ = Darwin.write(...)` and returned as if the send had
///    succeeded — so `espalier notify "done"` against a just-crashed
///    server reported success even though no notify was delivered.
///    Exactly Andy's "silent failure when the tool drops a signal"
///    pain point.
///
/// `writeAll` loops on partial bytes, retries on EINTR, and throws
/// on other errors. Matches the shape `WebSession.write` already uses
/// for PTY writes.
public enum SocketIO {

    public enum WriteError: Error, Equatable {
        /// `write(2)` returned -1 with a non-retriable errno (EPIPE,
        /// ECONNRESET, EBADF, etc.). The caller is expected to treat
        /// this as a hard send failure — the message is gone.
        case writeFailed(errno: Int32)
    }

    /// Write every byte in `bytes` to `fd`, looping on partial writes
    /// and retrying on EINTR. Throws `.writeFailed(errno:)` if the
    /// kernel returns -1 for any other reason.
    ///
    /// Note: no `count == 0` early-return — callers that pass a
    /// zero-length buffer get a zero-iteration loop and a successful
    /// return, matching `write(fd, _, 0)` semantics.
    public static func writeAll(
        fd: Int32,
        bytes: UnsafePointer<UInt8>,
        count: Int
    ) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw WriteError.writeFailed(errno: errno)
            }
            if n == 0 {
                // Zero without an error is unusual on sockets, but
                // treat as EPIPE-equivalent rather than spinning
                // indefinitely.
                throw WriteError.writeFailed(errno: EPIPE)
            }
            offset += n
        }
    }

    /// Convenience wrapper that writes the UTF-8 bytes of a `String`
    /// (without a trailing terminator).
    public static func writeAll(fd: Int32, string: String) throws {
        let bytes = Array(string.utf8)
        try bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            try writeAll(fd: fd, bytes: base, count: buf.count)
        }
    }
}

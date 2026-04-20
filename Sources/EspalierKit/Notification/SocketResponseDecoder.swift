import Foundation

/// Pure decoder for the byte buffer the CLI reads back from the
/// Espalier control socket. Extracted from the CLI's `SocketClient`
/// so the classification logic (timeout vs. unparseable vs. success)
/// is unit-testable without a running socket or process.
///
/// Why this matters: pre-cycle-138 `SocketClient.sendExpectingResponse`
/// lumped every empty-buffer outcome (client SO_RCVTIMEO elapsing,
/// server closing fd without a response per `ATTN-2.10`'s onRequest
/// timeout, server onRequest unset entirely) into
/// `CLIError.socketError("Empty response from app")`. That message
/// reads like a protocol bug when the real cause is almost always a
/// timeout — misleading Andy at exactly the moment he's trying to
/// diagnose a hang.
public enum SocketResponseDecoder {

    public enum Failure: Error, Equatable {
        /// Empty read: either the client's `SO_RCVTIMEO` (2s per
        /// `ATTN-3.3`) elapsed before any bytes arrived, or the
        /// server closed the fd without writing a response (main
        /// actor stalled past `ATTN-2.10`'s onRequestTimeout, or the
        /// server had no `onRequest` handler registered at all).
        /// Surfaces to the user as a timeout message because that's
        /// the overwhelming common case and the actionable cue is
        /// the same ("try again / wait for the app to un-stick").
        case timeout
        /// Bytes arrived but couldn't be parsed as a
        /// `ResponseMessage` JSON line. A genuine protocol error —
        /// shouldn't happen with the in-repo server but keeps the
        /// CLI honest against custom / older / third-party servers.
        case unparseable
    }

    public static func decode(_ buffer: Data) -> Result<ResponseMessage, Failure> {
        if buffer.isEmpty { return .failure(.timeout) }
        guard
            let str = String(data: buffer, encoding: .utf8),
            let line = str.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
            let data = line.data(using: .utf8)
        else {
            return .failure(.unparseable)
        }
        do {
            let msg = try JSONDecoder().decode(ResponseMessage.self, from: data)
            return .success(msg)
        } catch {
            return .failure(.unparseable)
        }
    }
}

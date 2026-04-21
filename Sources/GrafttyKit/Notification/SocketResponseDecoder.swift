import Foundation

/// Pure decoder for the byte buffer the CLI reads back from the
/// Graftty control socket. Separates timeout from protocol error so
/// the CLI can surface an actionable message.
public enum SocketResponseDecoder {

    public enum Failure: Error, Equatable {
        /// Empty read: client `SO_RCVTIMEO` elapsed, or the server
        /// closed fd without responding (`ATTN-2.10` onRequestTimeout,
        /// or no `onRequest` handler registered).
        case timeout
        /// Bytes arrived but couldn't be parsed as a `ResponseMessage`
        /// JSON line.
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

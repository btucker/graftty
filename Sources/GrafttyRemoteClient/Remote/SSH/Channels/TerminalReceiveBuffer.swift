import Foundation
import GrafttyProtocol
import NIOCore

/// Batches output already queued by SSH without delaying interactive output.
/// The owning client's lock protects this buffer.
struct TerminalReceiveBuffer {
    private static let batchByteLimit = 256 * 1024
    private var frames = CircularBuffer<WebSocketFrame>()

    mutating func append(_ frame: WebSocketFrame) {
        frames.append(frame)
    }

    mutating func popFirst() -> WebSocketFrame? {
        guard let first = frames.first else { return nil }
        guard case .binary(let bytes) = first else { return frames.removeFirst() }
        if frames.count == 1, bytes.count <= Self.batchByteLimit {
            return frames.removeFirst()
        }

        var batch = Data()
        while batch.count < Self.batchByteLimit,
              case .binary(let next)? = frames.first {
            let count = min(next.count, Self.batchByteLimit - batch.count)
            batch.append(next.prefix(count))
            if count == next.count {
                frames.removeFirst()
            } else {
                frames[frames.startIndex] = .binary(next.dropFirst(count))
            }
        }
        return .binary(batch)
    }
}

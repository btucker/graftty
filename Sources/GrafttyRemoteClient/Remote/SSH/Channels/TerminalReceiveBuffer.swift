import Foundation
import GrafttyProtocol
import NIOCore

/// Batches output already queued by SSH without delaying interactive output.
/// The owning client's lock protects this buffer.
struct TerminalReceiveBuffer {
    private static let batchByteLimit = 256 * 1024
    private var frames = CircularBuffer<WebSocketFrame>()
    private(set) var byteCount = 0
    private let byteLimit: Int
    private let frameLimit: Int

    init(byteLimit: Int = 8 * 1024 * 1024, frameLimit: Int = 1024) {
        self.byteLimit = byteLimit
        self.frameLimit = frameLimit
    }

    @discardableResult
    mutating func append(_ frame: WebSocketFrame) -> Bool {
        let count = Self.size(of: frame)
        guard frames.count < frameLimit, count <= byteLimit - byteCount else { return false }
        frames.append(frame)
        byteCount += count
        return true
    }

    mutating func removeAll() {
        frames = CircularBuffer()
        byteCount = 0
    }

    private static func size(of frame: WebSocketFrame) -> Int {
        switch frame {
        case .binary(let data): data.count
        case .text(let text): text.utf8.count
        }
    }

    mutating func popFirst() -> WebSocketFrame? {
        guard let first = frames.first else { return nil }
        guard case .binary(let bytes) = first else {
            byteCount -= Self.size(of: first)
            return frames.removeFirst()
        }
        if frames.count == 1, bytes.count <= Self.batchByteLimit {
            byteCount -= bytes.count
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
                // Copy the suffix so a small remainder cannot retain an entire large frame.
                frames[frames.startIndex] = .binary(Data(next.dropFirst(count)))
            }
        }
        byteCount -= batch.count
        return .binary(batch)
    }
}

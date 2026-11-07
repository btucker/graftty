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
        guard count <= byteLimit - byteCount else { return false }
        // SSH packet boundaries do not describe terminal records. Keep tiny
        // writes from exhausting the metadata budget while a grid or snapshot
        // operation briefly holds the receiver. Never cross a control frame.
        if case .binary(let data) = frame, !data.isEmpty,
           canExtendBinaryTail(by: count) {
            // Remove before appending so Data can reuse its unique storage.
            guard case .binary(var batch) = frames.removeLast() else { preconditionFailure() }
            batch.append(data)
            frames.append(.binary(batch))
            byteCount += count
            return true
        }
        guard frames.count < frameLimit else { return false }
        frames.append(frame)
        byteCount += count
        return true
    }

    private func canExtendBinaryTail(by count: Int) -> Bool {
        guard case .binary(let tail)? = frames.last, !tail.isEmpty else { return false }
        return tail.count <= Self.batchByteLimit - count
    }

    mutating func removeAll() {
        frames = CircularBuffer()
        byteCount = 0
    }

    private static func size(of frame: WebSocketFrame) -> Int {
        switch frame {
        case .binary(let data): data.count
        case .text(let text): text.utf8.count
        case .paged(let event):
            // The binary codec bounds metadata to 4 KiB. Account for it as
            // well as the retained payload without serializing a second time.
            switch event {
            case .checkpoint(let value): value.ready.count + 4096
            case .page(let value): value.data.count + 4096
            default: 4096
            }
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

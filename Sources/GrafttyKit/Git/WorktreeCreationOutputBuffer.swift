import Foundation
import GrafttyProtocol

public struct WorktreeCreationOutput: Sendable {
    public let text: String
    public let truncated: Bool
}

/// Each Git invocation owns one buffer. A newest-only stream plus throttled
/// snapshots bounds the backlog even if hooks write faster than the UI can render.
final class WorktreeCreationOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false
    private var lastPublished = ContinuousClock.now - .seconds(1)
    private var publicationScheduled = false
    private var finished = false
    private let continuation: AsyncStream<WorktreeCreationOutput>.Continuation?

    init(continuation: AsyncStream<WorktreeCreationOutput>.Continuation? = nil) {
        self.continuation = continuation
    }

    var snapshot: WorktreeCreationOutput { lock.withLock { makeSnapshot() } }

    func append(_ chunk: Data) {
        lock.withLock {
            bytes.append(chunk)
            let limit = WorktreeCreationProgress.maximumOutputBytes
            if bytes.count > limit {
                bytes = Data(bytes.suffix(limit))
                // Do not start the tail inside a UTF-8 scalar.
                while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
                truncated = true
            }
            let now = ContinuousClock.now
            if now - lastPublished >= .milliseconds(200) {
                continuation?.yield(makeSnapshot())
                lastPublished = now
            } else if !publicationScheduled {
                publicationScheduled = true
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.publishPending()
                }
            }
        }
    }

    private func publishPending() {
        lock.withLock {
            publicationScheduled = false
            guard !finished else { return }
            lastPublished = .now
            continuation?.yield(makeSnapshot())
        }
    }

    func finish() {
        lock.withLock {
            finished = true
            continuation?.yield(makeSnapshot())
            continuation?.finish()
        }
    }

    private func makeSnapshot() -> WorktreeCreationOutput {
        // Plain text only. In particular, never replay hook terminal-control
        // sequences when the CLI prints the diagnostic record.
        let plain = WorktreeCreationProgress.plainText(String(decoding: bytes, as: UTF8.self))
        // Invalid UTF-8 expands into replacement scalars. Bound the displayed
        // UTF-8 too, rather than only the original bytes.
        var encoded = Data(plain.utf8)
        let limit = WorktreeCreationProgress.maximumOutputBytes
        let expanded = encoded.count > limit
        if expanded {
            encoded = Data(encoded.suffix(limit))
            while let first = encoded.first, first & 0xC0 == 0x80 { encoded.removeFirst() }
        }
        return WorktreeCreationOutput(text: String(decoding: encoded, as: UTF8.self), truncated: truncated || expanded)
    }
}

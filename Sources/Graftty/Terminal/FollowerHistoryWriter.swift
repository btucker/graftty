import Foundation
import GhosttyKit

/// Owns a detached history surface. All state and lifecycle calls belong to
/// main; only the native write and its dispatch group run on the worker.
/// A single in-flight repaint bounds the backlog. The caller samples the
/// latest history again after completion instead of queuing stale snapshots.
final class FollowerHistoryWriter: @unchecked Sendable {
    let surface: ghostty_surface_t
    private let writes = DispatchGroup()
    private(set) var isWriting = false
    private var isClosed = false

    init(surface: ghostty_surface_t) { self.surface = surface }

    func repaint(_ data: Data, completion: @escaping @MainActor @Sendable () -> Void) {
        precondition(Thread.isMainThread)
        precondition(!isWriting && !isClosed)
        isWriting = true
        writes.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                ghostty_surface_write_buffer(surface, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
            }
            // Retirement waits for the C call, never for a main-queue block.
            writes.leave()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed else { return }
                self.isWriting = false
                ghostty_surface_refresh(self.surface)
                completion()
            }
        }
    }

    /// The view must retain the surface's backing NSView until this returns.
    /// Like InMemoryTerminalSurfaceAccess retirement, wait with mailbox
    /// progress and no Swift lock held. A plain join can deadlock against the
    /// parser's push into the 64-slot app mailbox. This is outside the parser
    /// callback, so ticking cannot reenter the native write on this thread.
    func close() {
        precondition(Thread.isMainThread)
        guard !isClosed else { return }
        isClosed = true
        while writes.wait(timeout: .now() + 0.001) == .timedOut {
            ghostty_app_tick(ghostty_surface_app(surface))
        }
        ghostty_surface_free(surface)
    }
}

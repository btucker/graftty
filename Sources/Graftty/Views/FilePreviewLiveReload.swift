import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol

/// Identifies one observed state of a source file. Comparing identity as well as
/// time and size notices atomic saves, which replace the file rather than write it.
/// The change time also moves with every write and when a permission change makes
/// an unreadable file readable, which leaves its modification time alone.
struct FilePreviewSourceSignature: Equatable, Sendable {
    private let device: Int64
    private let inode: UInt64
    private let size: Int64
    private let seconds: Int
    private let nanoseconds: Int

    init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        seconds = info.st_ctimespec.tv_sec
        nanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// Keeps each pane's latest preview following its source files.
///
/// Polling `stat` handles in-place writes, atomic replacement, and a file that
/// disappears and returns with one code path, where a vnode source would need
/// separate file and directory watches and re-arming after every atomic save.
/// Followed files are bounded by `maximumFollowed` and the 20-file collection limit.
@MainActor
final class FilePreviewLiveReload {
    static let shared = FilePreviewLiveReload(store: .shared, history: .shared, windows: .shared)
    static let maximumFollowed = ImagePreviewStore.maximumPreviews

    private struct Pane: Hashable {
        let worktreePath: String
        let sessionName: String
    }
    private let store: RemoteOpenStore
    private let history: FilePreviewHistory
    private let windows: FilePreviewWindows
    private let pollInterval: Duration
    private var followed: [Pane: Task<Void, Never>] = [:]
    private var order: [Pane] = []

    var followedCount: Int { followed.count }

    init(store: RemoteOpenStore, history: FilePreviewHistory, windows: FilePreviewWindows,
         pollInterval: Duration = .seconds(1)) {
        self.store = store
        self.history = history
        self.windows = windows
        self.pollInterval = pollInterval
    }

    /// `snapshots` is the published content, so a save that lands between that
    /// read and the first poll still counts as a change. Only its digest outlives
    /// this call, so a follow does not pin the published bytes in memory.
    @discardableResult
    func follow(group: UUID, urls: [URL], snapshots: [FilePreviewLoader.Snapshot],
                worktreePath: String, paneSessionName: String) -> Task<Void, Never> {
        let pane = Pane(worktreePath: worktreePath, sessionName: paneSessionName)
        stop(pane)
        if order.count >= Self.maximumFollowed, let oldest = order.first { stop(oldest) }
        order.append(pane)
        let published = Task.detached(priority: .utility) { Self.digest(of: snapshots) }
        let task = Task { [weak self, pollInterval] in
            var content = await published.value
            var signature: [FilePreviewSourceSignature?]?
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                guard let self else { return }
                let current = await Task.detached(priority: .utility) { urls.map(FilePreviewSourceSignature.init(url:)) }.value
                guard current != signature else { continue }
                let latest: [FilePreviewLoader.Snapshot]?
                do {
                    latest = try await Task.detached(priority: .utility) {
                        try Self.untornSnapshots(of: urls, observed: current)
                    }.value
                } catch {
                    // An unreadable file keeps the last good content. Its next signature
                    // change, including reappearing or regaining permission, tries again.
                    signature = current
                    continue
                }
                // Recording the signature only after a settled outcome makes the next
                // poll read a torn file again and retry a revision that failed.
                guard let latest else { continue }
                let latestContent = await Task.detached(priority: .utility) { Self.digest(of: latest) }.value
                guard !Task.isCancelled else { return }
                if latestContent != content {
                    do { try await self.apply(latest, urls: urls, group: group, worktreePath: worktreePath) } catch { continue }
                    content = latestContent
                }
                signature = current
            }
        }
        followed[pane] = task
        return task
    }

    /// Nil when a write landed during the read, which may have torn it.
    nonisolated static func untornSnapshots(of urls: [URL], observed: [FilePreviewSourceSignature?],
                                            load: ([URL]) throws -> [FilePreviewLoader.Snapshot] = FilePreviewLoader.snapshots) throws -> [FilePreviewLoader.Snapshot]? {
        let snapshots = try load(urls)
        return urls.map(FilePreviewSourceSignature.init(url:)) == observed ? snapshots : nil
    }

    func stopAll() {
        for pane in order { stop(pane) }
    }

    private func stop(_ pane: Pane) {
        followed.removeValue(forKey: pane)?.cancel()
        order.removeAll { $0 == pane }
    }

    private func apply(_ snapshots: [FilePreviewLoader.Snapshot], urls: [URL], group: UUID, worktreePath: String) async throws {
        let offers = try await store.revisePreview(group: group, snapshots: snapshots, worktree: worktreePath)
        try Task.checkCancellation()
        // A preview delivered only to mobile has no Mac snapshot to update.
        guard history.entries.contains(where: { $0.id == group && $0.worktreePath == worktreePath }) else { return }
        let files = try await Task.detached(priority: .utility) {
            try zip(snapshots, urls).map { try FilePreviewFile($0.0, sourceURL: $0.1) }
        }.value
        try Task.checkCancellation()
        windows.applyRevision(previewID: group, worktreePath: worktreePath, files: files,
                              contentRevision: offers.first?.contentRevision ?? 0)
    }

    private nonisolated static func digest(of snapshots: [FilePreviewLoader.Snapshot]) -> SHA256Digest {
        var hash = SHA256()
        for snapshot in snapshots {
            withUnsafeBytes(of: snapshot.bytes.count) { hash.update(bufferPointer: $0) }
            hash.update(data: snapshot.bytes)
        }
        return hash.finalize()
    }
}

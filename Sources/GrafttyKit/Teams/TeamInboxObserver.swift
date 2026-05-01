import Foundation
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// @spec TEAM-7.4
/// Watches a team's `messages.jsonl` file and emits the parsed message
/// list on every append. Survives the "file-not-yet-created" case by
/// also watching the parent directory for `.write`, reattaching the
/// file watcher when the file appears.
///
/// One observer per `(rootDirectory, teamID)` pair. View-only — does
/// not advance any cursor or watermark.
///
/// Concurrency: the callback fires on the observer's private dispatch
/// queue (utility QoS), not the main actor. Consumers that mutate
/// SwiftUI / `@Observable` state must hop to `MainActor` before
/// touching shared state.
public final class TeamInboxObserver: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "TeamInboxObserver")

    public final class Cancellable: @unchecked Sendable {
        private let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        public func cancel() { onCancel() }
    }

    private let inbox: TeamInbox
    private let teamID: String
    private let queue: DispatchQueue

    // Mutated only on `queue`.
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var dirFD: Int32 = -1

    public init(rootDirectory: URL, teamID: String) {
        self.inbox = TeamInbox(rootDirectory: rootDirectory)
        self.teamID = teamID
        self.queue = DispatchQueue(label: "com.btucker.graftty.TeamInboxObserver", qos: .utility)
    }

    /// Starts watching the inbox file. The callback is invoked on the
    /// observer's private dispatch queue (not main). The first
    /// invocation delivers the current on-disk state (which may be
    /// empty if the file does not yet exist).
    ///
    /// Calling `start` twice without an intervening `cancel()` is a
    /// programmer error — the second call is a no-op (returns a
    /// no-op `Cancellable`).
    public func start(_ callback: @escaping ([TeamInboxMessage]) -> Void) -> Cancellable {
        queue.async { [weak self] in
            guard let self else { return }
            self.attach(callback: callback)
            // Initial emit reflects the current on-disk state.
            self.emit(callback: callback)
        }
        return Cancellable { [weak self] in self?.tearDown() }
    }

    private func attach(callback: @escaping ([TeamInboxMessage]) -> Void) {
        // Idempotent guard: if a previous `start` is still active, leave
        // its sources in place rather than orphaning their file
        // descriptors.
        guard dirSource == nil else { return }

        let messagesURL = TeamInbox.messagesURLFor(
            rootDirectory: inbox.rootDirectory,
            teamID: teamID
        )
        let parentURL = messagesURL.deletingLastPathComponent()

        // Ensure parent dir exists so we can watch it before any append
        // ever creates the messages file.
        try? FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        // Watch parent directory: a new entry (the messages.jsonl file
        // appearing for the first time) fires `.write`, at which point
        // we reattach the per-file source.
        dirFD = open(parentURL.path, O_EVTONLY)
        if dirFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: [.write],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.attachFileSource(callback: callback)
                self.emit(callback: callback)
            }
            // Explicitly close the dir fd in the cancel handler; the
            // dispatch source does not own the fd by default.
            let dirFDCopy = dirFD
            src.setCancelHandler {
                close(dirFDCopy)
            }
            src.resume()
            dirSource = src
        }

        attachFileSource(callback: callback)
    }

    private func attachFileSource(callback: @escaping ([TeamInboxMessage]) -> Void) {
        let messagesURL = TeamInbox.messagesURLFor(
            rootDirectory: inbox.rootDirectory,
            teamID: teamID
        )

        // Tear down any existing file source — covers both the
        // first-time attach (no-op) and the inode-replaced-by-truncate
        // case where the previous fd points at a stale inode.
        fileSource?.cancel()
        fileSource = nil
        if fileFD >= 0 {
            close(fileFD)
            fileFD = -1
        }

        guard FileManager.default.fileExists(atPath: messagesURL.path) else { return }
        fileFD = open(messagesURL.path, O_EVTONLY)
        guard fileFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            // On delete/rename, the file watch is now bound to a stale
            // inode; reattach via the parent dir watcher's pathway. The
            // next `.write` to the parent will trigger a fresh attach.
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.attachFileSource(callback: callback)
                return
            }
            self.emit(callback: callback)
        }
        let fileFDCopy = fileFD
        src.setCancelHandler {
            close(fileFDCopy)
        }
        src.resume()
        fileSource = src
    }

    private func emit(callback: @escaping ([TeamInboxMessage]) -> Void) {
        do {
            let messages = try inbox.messages(teamID: teamID)
            callback(messages)
        } catch {
            Self.logger.error("inbox read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func tearDown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileSource?.cancel()
            self.fileSource = nil
            self.fileFD = -1
            self.dirSource?.cancel()
            self.dirSource = nil
            self.dirFD = -1
        }
    }

    deinit {
        // Tear down synchronously: by deinit, no Cancellable is alive to
        // call cancel(), but the dispatch sources still hold the fds.
        // Cancel inline (no `queue.async`) since `self` is going away.
        fileSource?.cancel()
        dirSource?.cancel()
    }
}

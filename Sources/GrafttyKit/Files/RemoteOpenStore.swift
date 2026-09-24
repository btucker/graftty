import Foundation
import GrafttyProtocol
import Darwin

/// Holds explicit file offers, never a remotely supplied filesystem path.
/// Bytes are snapshotted so edits on the host cannot corrupt an in-flight preview.
public actor RemoteOpenStore {
    public static let shared = RemoteOpenStore()
    private struct Entry {
        let offer: RemoteOpenOffer
        let worktree: String
        let bytes: Data
        let expires: Date
    }
    private var entries: [Entry] = []
    public init() {}

    public enum Failure: LocalizedError {
        case invalidFile, tooLarge, expired, invalidOffset
        public var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a readable regular file."
            case .tooLarge: "File previews are limited to 20 MB."
            case .expired: "This file offer expired. Run graftty open again."
            case .invalidOffset: "Invalid file download offset."
            }
        }
    }

    public func offer(file: URL, worktree: String, now: Date = Date()) throws -> RemoteOpenOffer {
        if !file.isFileURL {
            guard ["http", "https"].contains(file.scheme?.lowercased() ?? ""),
                  file.host != nil, file.user == nil, file.password == nil else { throw Failure.invalidFile }
            purge(now: now)
            if entries.count >= 20 { entries.removeFirst() }
            let expires = now.addingTimeInterval(900)
            let offer = RemoteOpenOffer(id: UUID(), filename: file.absoluteString, byteCount: 0, url: file)
            entries.append(Entry(offer: offer, worktree: worktree, bytes: Data(), expires: expires))
            BrowserTunnelApprovalStore.shared.approve(until: expires)
            return offer
        }
        // O_NONBLOCK prevents a named pipe from hanging the request before fstat.
        let fd = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure.invalidFile
        }
        guard info.st_size <= RemoteOpenOffer.maxBytes else { throw Failure.tooLarge }
        let bytes = try handle.read(upToCount: RemoteOpenOffer.maxBytes + 1) ?? Data()
        guard bytes.count <= RemoteOpenOffer.maxBytes else { throw Failure.tooLarge }
        purge(now: now)
        while entries.count >= 20 || entries.reduce(0, { $0 + $1.bytes.count }) + bytes.count > 50 * 1024 * 1024 {
            entries.removeFirst()
        }
        let offer = RemoteOpenOffer(id: UUID(), filename: file.lastPathComponent, byteCount: bytes.count)
        entries.append(Entry(offer: offer, worktree: worktree, bytes: bytes, expires: now.addingTimeInterval(900)))
        return offer
    }

    public func list(worktree: String, now: Date = Date()) -> [RemoteOpenOffer] {
        purge(now: now)
        return entries.filter { $0.worktree == worktree }.map(\.offer)
    }

    public func read(id: UUID, worktree: String, offset: Int, now: Date = Date()) throws -> Data {
        purge(now: now)
        guard let entry = entries.first(where: { $0.offer.id == id && $0.worktree == worktree }) else {
            throw Failure.expired
        }
        guard offset >= 0, offset <= entry.bytes.count else { throw Failure.invalidOffset }
        return entry.bytes.subdata(in: offset..<min(entry.bytes.count, offset + RemoteOpenOffer.chunkBytes))
    }

    private func purge(now: Date) { entries.removeAll { $0.expires <= now } }
}

/// Records the Mac user's short-lived approval created by `graftty open URL`.
/// The SSH host still applies each paired device's port-tunnel capability;
/// this store only supplies the approval required by `askEachTime`.
public final class BrowserTunnelApprovalStore: @unchecked Sendable {
    public static let shared = BrowserTunnelApprovalStore()
    private let lock = NSLock()
    private var approvedUntil = Date.distantPast

    public init() {}

    public func approve(until expiry: Date) {
        lock.lock()
        approvedUntil = max(approvedUntil, expiry)
        lock.unlock()
    }

    public func isApproved(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approvedUntil > now
    }
}

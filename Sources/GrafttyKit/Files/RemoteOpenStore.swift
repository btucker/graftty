import Foundation
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Holds explicit file offers, never a remotely supplied filesystem path.
/// Bytes are snapshotted so edits on the host cannot corrupt an in-flight preview.
public actor RemoteOpenStore {
    public static let shared = RemoteOpenStore()
    private struct Entry {
        let offer: RemoteOpenOffer
        let worktree: String
        let bytes: Data
        let expires: Date
        let previewRevision: UInt64?
    }
    private var entries: [Entry] = []
    public init() {}

    public enum Failure: LocalizedError {
        case invalidFile, invalidBrowserOwner, tooLarge, expired, invalidOffset, superseded
        public var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a readable regular file."
            case .invalidBrowserOwner: "The mobile browser owner is unavailable. Try again."
            case .tooLarge: "File previews are limited to 20 MB."
            case .expired: "This file offer expired. Run graftty open again."
            case .invalidOffset: "Invalid file download offset."
            case .superseded: "A newer request already replaced this preview."
            }
        }
    }

    public func offer(
        file: URL,
        worktree: String,
        browserOwnerClientID: DisplayClientID? = nil,
        paneSessionName: String? = nil,
        now: Date = Date()
    ) throws -> RemoteOpenOffer {
        if !file.isFileURL {
            guard ["http", "https"].contains(file.scheme?.lowercased() ?? ""),
                  file.host != nil, file.user == nil, file.password == nil else { throw Failure.invalidFile }
            purge(now: now)
            let expires = now.addingTimeInterval(900)
            guard let browserOwnerClientID,
                  let deviceID = BrowserTunnelApprovalStore.deviceID(for: browserOwnerClientID),
                  BrowserTunnelApprovalStore.shared.approve(ownerClientID: browserOwnerClientID, until: expires) else {
                throw Failure.invalidBrowserOwner
            }
            if entries.count >= 20 { evictOldest() }
            let offer = RemoteOpenOffer(id: UUID(), filename: file.absoluteString, byteCount: 0, url: file,
                                        paneSessionName: paneSessionName, browserOwnerDeviceID: deviceID)
            entries.append(Entry(offer: offer, worktree: worktree, bytes: Data(), expires: expires, previewRevision: nil))
            return offer
        }
        // O_NONBLOCK prevents a named pipe from hanging the request before fstat.
        let fd = GrafttyPOSIX.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
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
        return try offerSnapshot(bytes: bytes, filename: file.lastPathComponent, worktree: worktree,
                                 paneSessionName: paneSessionName, now: now)
    }

    /// Inserts a collection atomically so polling never observes half a request.
    public func offerPreviews(_ snapshots: [FilePreviewLoader.Snapshot], worktree: String,
                              paneSessionName: String, previewRevision: UInt64,
                              ownerDeviceID: RemoteDeviceID, now: Date = Date()) throws -> [RemoteOpenOffer] {
        guard (1...FilePreviewLoader.maximumFiles).contains(snapshots.count) else {
            throw FilePreviewLoader.Failure.invalidCollection
        }
        guard snapshots.allSatisfy({ $0.bytes.count <= RemoteOpenOffer.maxBytes }),
              snapshots.reduce(0, { $0 + $1.bytes.count }) <= FilePreviewLoader.maximumTotalBytes else { throw Failure.tooLarge }
        guard snapshots.allSatisfy({ !$0.filename.isEmpty && $0.filename != "." && $0.filename != ".."
            && !$0.filename.contains("/") && !$0.filename.contains("\0") }) else { throw Failure.invalidFile }
        purge(now: now)
        guard !entries.contains(where: { $0.worktree == worktree && $0.offer.paneSessionName == paneSessionName
            && ($0.previewRevision ?? 0) > previewRevision }) else { throw Failure.superseded }
        entries.removeAll { $0.worktree == worktree && $0.offer.paneSessionName == paneSessionName && $0.previewRevision != nil }
        let byteCount = snapshots.reduce(0) { $0 + $1.bytes.count }
        while entries.count + snapshots.count > 20 || entries.reduce(0, { $0 + $1.bytes.count }) + byteCount > FilePreviewLoader.maximumTotalBytes {
            evictOldest()
        }
        let group = UUID()
        return snapshots.map { snapshot in
            let offer = RemoteOpenOffer(id: UUID(), filename: snapshot.filename, byteCount: snapshot.bytes.count,
                                       paneSessionName: paneSessionName, previewKind: "file",
                                       previewOwnerDeviceID: ownerDeviceID, previewGroupID: group)
            entries.append(Entry(offer: offer, worktree: worktree, bytes: snapshot.bytes,
                                 expires: now.addingTimeInterval(900), previewRevision: previewRevision))
            return offer
        }
    }

    /// Offers bytes already read and validated by a native preview loader.
    public func offerSnapshot(bytes: Data, filename: String, worktree: String,
                              paneSessionName: String? = nil, previewRevision: UInt64? = nil,
                              previewKind: String? = nil, previewOwnerDeviceID: RemoteDeviceID? = nil,
                              now: Date = Date()) throws -> RemoteOpenOffer {
        guard bytes.count <= RemoteOpenOffer.maxBytes else { throw Failure.tooLarge }
        guard !filename.isEmpty, URL(fileURLWithPath: filename).lastPathComponent == filename else { throw Failure.invalidFile }
        purge(now: now)
        if let previewRevision, let paneSessionName {
            let priorPreviews = entries.filter {
                $0.worktree == worktree && $0.offer.paneSessionName == paneSessionName && $0.previewRevision != nil
            }
            guard !priorPreviews.contains(where: { ($0.previewRevision ?? 0) > previewRevision }) else { throw Failure.superseded }
            entries.removeAll {
                $0.worktree == worktree && $0.offer.paneSessionName == paneSessionName && $0.previewRevision != nil
            }
        }
        while entries.count >= 20 || entries.reduce(0, { $0 + $1.bytes.count }) + bytes.count > 50 * 1024 * 1024 {
            evictOldest()
        }
        let offer = RemoteOpenOffer(id: UUID(), filename: filename, byteCount: bytes.count, paneSessionName: paneSessionName,
                                    previewKind: previewKind, previewOwnerDeviceID: previewOwnerDeviceID)
        entries.append(Entry(offer: offer, worktree: worktree, bytes: bytes, expires: now.addingTimeInterval(900),
                             previewRevision: previewRevision))
        return offer
    }

    public func withdraw(id: UUID, worktree: String) {
        guard let entry = entries.first(where: { $0.offer.id == id && $0.worktree == worktree }) else { return }
        if let group = entry.offer.previewGroupID {
            entries.removeAll { $0.offer.previewGroupID == group && $0.worktree == worktree }
        } else { entries.removeAll { $0.offer.id == id && $0.worktree == worktree } }
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

    private func evictOldest() {
        guard let first = entries.first else { return }
        if let group = first.offer.previewGroupID {
            entries.removeAll { $0.offer.previewGroupID == group }
        } else { entries.removeFirst() }
    }

    private func purge(now: Date) { entries.removeAll { $0.expires <= now } }
}

/// Records the Mac user's short-lived approval created by `graftty open URL`.
/// The SSH host still applies each paired device's port-tunnel capability;
/// this store only supplies the approval required by `askEachTime`.
public final class BrowserTunnelApprovalStore: @unchecked Sendable {
    public static let shared = BrowserTunnelApprovalStore()
    private let lock = NSLock()
    private var approvedUntil: [RemoteDeviceID: Date] = [:]
    private struct Endpoint: Hashable {
        let host: String
        let port: UInt16
    }
    private var portApprovals: [RemoteDeviceID: [Endpoint: Date]] = [:]

    public init() {}

    public func approve(deviceID: RemoteDeviceID, host: String = "localhost", port: UInt16, until expiry: Date) {
        guard port > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let endpoint = Endpoint(host: Self.approvalHost(host), port: port)
        portApprovals[deviceID, default: [:]][endpoint] = max(portApprovals[deviceID]?[endpoint] ?? .distantPast, expiry)
    }

    public func isApproved(deviceID: RemoteDeviceID, host: String, port: Int, now: Date = Date()) -> Bool {
        if isApproved(deviceID: deviceID, now: now) { return true }
        guard let port = UInt16(exactly: port), port > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        portApprovals[deviceID] = portApprovals[deviceID]?.filter { $0.value > now }
        return (portApprovals[deviceID]?[Endpoint(host: Self.approvalHost(host), port: port)] ?? .distantPast) > now
    }

    private static func approvalHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    public static func deviceID(for ownerClientID: DisplayClientID) -> RemoteDeviceID? {
        // TerminalSessionHandler names mobile owners ssh-<device ID>-<session UUID>.
        let raw = ownerClientID.rawValue
        guard raw.hasPrefix("ssh-"), raw.count > 41 else { return nil }
        let suffix = String(raw.suffix(37))
        guard suffix.first == "-", UUID(uuidString: String(suffix.dropFirst())) != nil else { return nil }
        let device = String(raw.dropFirst(4).dropLast(37))
        guard !device.isEmpty else { return nil }
        return RemoteDeviceID(value: device)
    }

    public func approve(ownerClientID: DisplayClientID, until expiry: Date) -> Bool {
        guard let deviceID = Self.deviceID(for: ownerClientID) else { return false }
        lock.lock()
        approvedUntil[deviceID] = max(approvedUntil[deviceID] ?? .distantPast, expiry)
        lock.unlock()
        return true
    }

    public func isApproved(deviceID: RemoteDeviceID, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expiry = approvedUntil[deviceID] else { return false }
        if expiry > now { return true }
        approvedUntil.removeValue(forKey: deviceID)
        return false
    }
}

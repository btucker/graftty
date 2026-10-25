import Foundation
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Parent-owned authority for one assignment. This contains public peer identity,
/// never keys or credentials. Installing it does not authorize origin publication.
public struct GitDelegation: Codable, Sendable, Equatable {
    public let id: UUID
    public let generation: UInt64
    public let repositoryID: UUID
    public let host: RemoteMacConnectionSummary.ID
    public let remoteWorktreeID: String
    public let allowedRefs: [String]
    public let expiresAt: Date

    public init(id: UUID, generation: UInt64, repositoryID: UUID, host: RemoteMacConnectionSummary.ID,
                remoteWorktreeID: String, allowedRefs: [String], expiresAt: Date) {
        self.id = id; self.generation = generation; self.repositoryID = repositoryID; self.host = host
        self.remoteWorktreeID = remoteWorktreeID; self.allowedRefs = allowedRefs; self.expiresAt = expiresAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.generation == rhs.generation && lhs.repositoryID == rhs.repositoryID
            && lhs.host.fingerprint == rhs.host.fingerprint && lhs.host.deviceID.value.utf8.elementsEqual(rhs.host.deviceID.value.utf8)
            && lhs.remoteWorktreeID.utf8.elementsEqual(rhs.remoteWorktreeID.utf8)
            && lhs.allowedRefs.map({ Data($0.utf8) }) == rhs.allowedRefs.map({ Data($0.utf8) }) && lhs.expiresAt == rhs.expiresAt
    }
}

public enum GitDelegationError: Error, Equatable {
    case invalidAssignment, invalidStore, historyFull, changedRetry, staleGeneration, wrongRepository, unauthorized
}

/// Reload under an interprocess lock for every access so app and CLI callers
/// observe revocation and reassignment immediately. Corrupt state fails closed.
/// Authorization is a point-in-time check, not a transferable capability: receive
/// code must check again before updating refs and must never expose install to peers.
public struct GitDelegationStore: Sendable {
    private struct Entry: Codable, Equatable { var delegation: GitDelegation; var revoked = false }
    private struct Document: Codable, Equatable { var version = 1; var records: [Entry] = [] }
    private static let processLock = NSLock()
    public let directory: URL
    private var file: JSONFileStore<Document> {
        .init(fileURL: directory.appendingPathComponent("delegations.json"), outputFormatting: [.sortedKeys], posixPermissions: 0o600)
    }
    public init(directory: URL) { self.directory = directory }

    public func install(_ delegation: GitDelegation, at now: Date = Date()) throws {
        try Self.validate(delegation)
        guard now.timeIntervalSince1970.isFinite, delegation.expiresAt > now else { throw GitDelegationError.invalidAssignment }
        try access { document in
            if let index = document.records.firstIndex(where: { $0.delegation.id == delegation.id }) {
                let previous = document.records[index]
                if delegation.generation == previous.delegation.generation {
                    guard !previous.revoked, delegation == previous.delegation else { throw GitDelegationError.changedRetry }
                    return
                }
                guard previous.delegation.generation < UInt64.max,
                      delegation.generation == previous.delegation.generation + 1 else { throw GitDelegationError.staleGeneration }
                guard delegation.repositoryID == previous.delegation.repositoryID else { throw GitDelegationError.wrongRepository }
                document.records[index] = Entry(delegation: delegation)
            } else {
                guard delegation.generation == 1 else { throw GitDelegationError.staleGeneration }
                guard document.records.count < 10000 else { throw GitDelegationError.historyFull }
                document.records.append(Entry(delegation: delegation))
            }
        }
    }

    public func revoke(id: UUID, generation: UInt64) throws {
        try access { document in
            guard let index = document.records.firstIndex(where: { $0.delegation.id == id }),
                  document.records[index].delegation.generation == generation else { throw GitDelegationError.staleGeneration }
            document.records[index].revoked = true
        }
    }

    public func authorize(_ scope: GitDelegationScope, authenticatedPeer: RemoteMacConnectionSummary.ID,
                          at now: Date = Date()) throws -> GitDelegation {
        try access { document in
            guard now.timeIntervalSince1970.isFinite,
                  let entry = document.records.first(where: { $0.delegation.id == scope.delegationID }), !entry.revoked else {
                throw GitDelegationError.unauthorized
            }
            let delegation = entry.delegation
            guard delegation.host.fingerprint == authenticatedPeer.fingerprint,
                  delegation.host.deviceID.value.utf8.elementsEqual(authenticatedPeer.deviceID.value.utf8),
                  delegation.generation == scope.generation, delegation.repositoryID == scope.repositoryID,
                  delegation.remoteWorktreeID.utf8.elementsEqual(scope.remoteWorktreeID.utf8), delegation.expiresAt > now,
                  !scope.refs.isEmpty, scope.refs.count <= 128 else { throw GitDelegationError.unauthorized }
            // Git compares ref bytes. Swift String equality normalizes Unicode,
            // which must not grant a different, canonically equivalent ref name.
            let requested = scope.refs.map { Data($0.utf8) }
            let allowed = Set(delegation.allowedRefs.map { Data($0.utf8) })
            guard Set(requested).count == requested.count, requested.allSatisfy(allowed.contains) else { throw GitDelegationError.unauthorized }
            return delegation
        }
    }

    private func access<T>(_ body: (inout Document) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("delegations.lock").path
        let flags = O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC
        #if canImport(Darwin)
        let descriptor = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
        #else
        let descriptor = Glibc.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
        #endif
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var document = try file.load() ?? Document()
        guard document.version == 1, document.records.count <= 10000,
              Set(document.records.map(\.delegation.id)).count == document.records.count else { throw GitDelegationError.invalidStore }
        for entry in document.records { try Self.validate(entry.delegation) }
        let original = document
        let result = try body(&document)
        if original != document { try file.save(document) }
        return result
    }

    private static func validate(_ delegation: GitDelegation) throws {
        let path = delegation.remoteWorktreeID
        guard delegation.generation > 0, delegation.expiresAt.timeIntervalSince1970.isFinite,
              !delegation.host.deviceID.value.isEmpty, delegation.host.deviceID.value.utf8.count <= 256,
              !delegation.host.deviceID.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.hasPrefix("/"), path.utf8.count <= 4096,
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !delegation.allowedRefs.isEmpty, delegation.allowedRefs.count <= 128,
              Set(delegation.allowedRefs.map { Data($0.utf8) }).count == delegation.allowedRefs.count,
              delegation.allowedRefs.allSatisfy(validBranchRef) else { throw GitDelegationError.invalidAssignment }
    }

    private static func validBranchRef(_ ref: String) -> Bool {
        guard ref.hasPrefix("refs/heads/"), ref.utf8.count <= 1024, !ref.hasSuffix("."),
              !ref.contains(".."), !ref.contains("@{"),
              !ref.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) }) else { return false }
        return ref.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }
}

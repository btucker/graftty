import Darwin
import Foundation

/// Uses a stable sidecar inode because atomic journal writes replace theirs.
/// A stopped helper retains ownership until it exits; no other recoverer may
/// take over a journal while that helper could execute again.
public final class WorktreeSleepRecoveryLease {
    private let descriptor: Int32
    public init?(journal: URL) {
        let descriptor = open(journal.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        self.descriptor = descriptor
    }
    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct SleepGuardReadiness: Codable {
    public let identity: SleepProcessIdentity
    public let uptime: TimeInterval
    public init(identity: SleepProcessIdentity, uptime: TimeInterval) { self.identity = identity; self.uptime = uptime }
}

/// One journal per application process. Atomic writes retain exact process
/// identities; journals from other running instances are never consumed.
public struct WorktreeSleepJournal: Codable, Sendable {
    public let owner: SleepProcessIdentity
    public var processes: [SuspendedSleepProcess]

    public init(owner: SleepProcessIdentity, processes: [SuspendedSleepProcess] = []) {
        self.owner = owner; self.processes = processes
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) -> WorktreeSleepJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Returns the unresumed records. Missing/reused identities are removed,
    /// while unreadable live PIDs and failed signals remain for later retry.
    public mutating func recover(
        identity: (Int32) -> Int64? = ProcessIdentityReader.startTimeMicroseconds,
        read: (Int32) -> SleepProcessSample? = SleepProcessReader.sample,
        signal: (SleepProcessIdentity, Bool) -> Bool = SleepProcessReader.signal
    ) {
        processes = processes.filter { record in
            guard let start = identity(record.identity.pid) else {
                // If the kernel still reports the PID alive but denies its
                // identity, uncertainty must retain the recovery record.
                return Self.isAlive(record.identity.pid)
            }
            guard start == record.identity.startTime else { return false }
            guard let current = read(record.identity.pid) else { return true }
            guard current.identity == record.identity else { return false }
            return !signal(record.identity, false)
        }
    }

    public var ownerIsAlive: Bool {
        if let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: owner.pid) { return start == owner.startTime }
        return Self.isAlive(owner.pid)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}

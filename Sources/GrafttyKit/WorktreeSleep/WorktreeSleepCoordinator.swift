import Foundation

public struct WorktreeSleepEvidence {
    public var enabled = false
    public var keepAwake = false
    public var hasViewer = false
    public var allPanesInactive = false
    public var providerActivityKnownIdle = false
    public var processActivityKnownIdle = false

    public init() {}
    public var allowsSleep: Bool {
        enabled && !keepAwake && !hasViewer && allPanesInactive
            && providerActivityKnownIdle && processActivityKnownIdle
    }
}

public struct SleepProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTime: Int64
    public init(pid: Int32, startTime: Int64) { self.pid = pid; self.startTime = startTime }
}

public struct SleepProcessSample: Equatable, Sendable {
    public let identity: SleepProcessIdentity
    public let cpuNanoseconds: UInt64
    public let diskBytes: UInt64
    public var isStopped: Bool

    public init(identity: SleepProcessIdentity, cpuNanoseconds: UInt64, diskBytes: UInt64, isStopped: Bool) {
        self.identity = identity
        self.cpuNanoseconds = cpuNanoseconds
        self.diskBytes = diskBytes
        self.isStopped = isStopped
    }
}

/// Samples use monotonic uptime. A missing sample or a gap longer than two
/// polling intervals invalidates the observation window, including Mac sleep.
public struct WorktreeSleepActivityWindow {
    private var previous: [SleepProcessSample]?
    private var lastSample: TimeInterval?
    private var idleSince: TimeInterval?
    public init() {}

    public mutating func reset() { previous = nil; lastSample = nil; idleSince = nil }

    public mutating func observe(_ samples: [SleepProcessSample]?, at time: TimeInterval, duration: TimeInterval) -> Bool {
        guard let samples, !samples.isEmpty, samples.allSatisfy({ !$0.isStopped }) else {
            reset()
            return false
        }
        let ordered = samples.sorted { $0.identity.pid < $1.identity.pid }
        defer { previous = ordered; lastSample = time }
        guard let previous, let lastSample, time >= lastSample, time - lastSample <= 60,
              previous.map(\.identity) == ordered.map(\.identity),
              zip(previous, ordered).allSatisfy({ old, new in
                  new.cpuNanoseconds >= old.cpuNanoseconds && new.diskBytes >= old.diskBytes
                      && new.cpuNanoseconds - old.cpuNanoseconds <= 1_000_000
                      && new.diskBytes == old.diskBytes
              }) else {
            idleSince = time
            return false
        }
        return time - (idleSince ?? time) >= duration
    }
}

public struct SuspendedSleepProcess: Codable, Hashable, Sendable {
    public let path: String
    public let identity: SleepProcessIdentity
    public init(path: String, identity: SleepProcessIdentity) { self.path = path; self.identity = identity }
}

/// Serializes signals and wake requests across the UI, host attach, and
/// delivery paths. Journal writes precede SIGSTOP so crash recovery owns
/// every signal that may have been sent, even if the app dies mid-call.
public final class WorktreeSleepCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let read: (SleepProcessIdentity) -> SleepProcessSample?
    private let signal: (SleepProcessIdentity, Bool) -> Bool
    private let persist: ([SuspendedSleepProcess]) -> Bool
    private let recoveryReady: () -> Bool
    private let identityExists: (SleepProcessIdentity) -> Bool?
    private var records: [SuspendedSleepProcess] = []
    private var resumedPendingSave: Set<SuspendedSleepProcess> = []
    private var sessionPaths: [String: String] = [:]
    private var generation: UInt64 = 0
    private var lastInteraction: [String: TimeInterval] = [:]
    private var lastInputBoundaries: [String: TimeInterval] = [:]

    public func lastInputBoundary(session: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return lastInputBoundaries[session] ?? 0
    }

    @discardableResult public func wakeForInput(session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let path = sessionPaths[session] else { return wake(session: session) }
        lastInputBoundaries[session] = Date().timeIntervalSince1970
        return wake(path: path)
    }

    public func lastInteractionUptime(path: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastInteraction[path]
    }

    public init(read: @escaping (SleepProcessIdentity) -> SleepProcessSample?,
                signal: @escaping (SleepProcessIdentity, Bool) -> Bool,
                persist: @escaping ([SuspendedSleepProcess]) -> Bool,
                recoveryReady: @escaping () -> Bool,
                identityExists: @escaping (SleepProcessIdentity) -> Bool? = SleepProcessReader.identityExists) {
        self.read = read; self.signal = signal; self.persist = persist; self.recoveryReady = recoveryReady
        self.identityExists = identityExists
    }

    @discardableResult public func register(session: String, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let previous = sessionPaths[session], previous != path, !wake(path: previous) { return false }
        if lastInputBoundaries[session] == nil { lastInputBoundaries[session] = Date().timeIntervalSince1970 }
        sessionPaths[session] = path
        return true
    }

    public var suspendedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(records.map(\.path))
    }

    public func isSleeping(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records.contains { $0.path == path }
    }

    public func suspend(path: String, processes: [SleepProcessSample], recheck: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let startingGeneration = generation
        guard !processes.isEmpty, !isSleeping(path: path), recoveryReady(), recheck(),
              generation == startingGeneration,
              Set(processes.map(\.identity)).count == processes.count,
              processes.allSatisfy({ sample in
                  guard !sample.isStopped, let current = read(sample.identity) else { return false }
                  return current.identity == sample.identity && !current.isStopped
                      && current.cpuNanoseconds >= sample.cpuNanoseconds
                      && current.cpuNanoseconds - sample.cpuNanoseconds <= 1_000_000
                      && current.diskBytes == sample.diskBytes
              }) else { return false }
        for sample in processes {
            guard recoveryReady(), recheck(), generation == startingGeneration,
                  let current = read(sample.identity), current.identity == sample.identity, !current.isStopped else {
                _ = wake(path: path)
                return false
            }
            let entry = SuspendedSleepProcess(path: path, identity: sample.identity)
            let next = records + [entry]
            guard persist(next) else { _ = wake(path: path); return false }
            records = next
            guard signal(sample.identity, true) else {
                // A failed kill cannot have stopped this process. Do not send
                // SIGCONT to it in rollback, including externally stopped jobs.
                resumedPendingSave.insert(entry)
                _ = wake(path: path)
                return false
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.1
            while let current = read(sample.identity), current.identity == sample.identity,
                  !current.isStopped, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard let stopped = read(sample.identity), stopped.identity == sample.identity, stopped.isStopped else {
                _ = wake(path: path)
                return false
            }
        }
        guard recheck(), generation == startingGeneration, recoveryReady() else {
            _ = wake(path: path)
            return false
        }
        return true
    }

    @discardableResult public func wake(session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        guard let path = sessionPaths[session] else { return true }
        return wake(path: path)
    }

    @discardableResult public func wake(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        lastInteraction[path] = ProcessInfo.processInfo.systemUptime
        guard records.contains(where: { $0.path == path }) else { return true }
        var retained: [SuspendedSleepProcess] = []
        for entry in records {
            guard entry.path == path else { retained.append(entry); continue }
            if resumedPendingSave.contains(entry) { continue }
            guard let current = read(entry.identity) else {
                if identityExists(entry.identity) != false { retained.append(entry) }
                continue
            }
            guard current.identity == entry.identity else { continue }
            if signal(entry.identity, false) { resumedPendingSave.insert(entry) }
            else { retained.append(entry) }
        }
        guard persist(retained) else { return false }
        records = retained
        resumedPendingSave.formIntersection(Set(retained))
        return !isSleeping(path: path)
    }

    @discardableResult public func wakeAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var success = true
        for path in Set(records.map(\.path)) { if !wake(path: path) { success = false } }
        return success
    }
}

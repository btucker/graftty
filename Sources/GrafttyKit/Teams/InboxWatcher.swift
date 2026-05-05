import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Test-friendly outcome collector for `InboxWatcher`. Production driver
/// (the `watch-inbox` CLI subcommand) awaits the result and then calls
/// `exit()` itself; tests await it without exiting the test runner.
public actor WatcherOutcome {
    public struct Result: Sendable, Equatable {
        public let exitCode: Int32
        public let stderr: String
        public init(exitCode: Int32, stderr: String) {
            self.exitCode = exitCode
            self.stderr = stderr
        }
    }

    public enum WaitError: Error {
        case timeout
    }

    private var completed: Result?

    public init() {}

    public func complete(exitCode: Int32, stderr: String) {
        guard completed == nil else { return }
        completed = Result(exitCode: exitCode, stderr: stderr)
    }

    public func wait(timeout: TimeInterval) async throws -> Result {
        if let r = completed { return r }
        // Poll the actor state on a short cadence so this works whether
        // `complete` is called synchronously inside the actor or from a
        // separate task. Avoids the foot-gun of a parked
        // `CheckedContinuation` inside a TaskGroup (cancellation does not
        // resume the continuation, so the group never tears down).
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if let r = completed { return r }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let r = completed { return r }
        throw WaitError.timeout
    }
}

/// @spec TEAM-IDLE-1.3
/// @spec TEAM-IDLE-1.4
/// Long-running watcher used by Claude's `asyncRewake` Stop hook. Writes
/// its own PID to `<pidFileRoot>/<teamID>/watchers/<session>.<runtime>.pid`,
/// SIGTERMing whatever PID was previously there (one watcher per session,
/// deterministically — the next Stop firing supersedes the prior watcher).
/// Then tails the inbox JSONL via `TeamInboxObserver` and resolves
/// `outcome` with exit-code 2 + a stderr summary the first time a fresh
/// message addressed to its recipient arrives.
public actor InboxWatcher {
    public struct Recipient: Sendable, Equatable {
        public let member: String
        public let runtime: TeamHookRuntime
        public init(member: String, runtime: TeamHookRuntime) {
            self.member = member
            self.runtime = runtime
        }
    }

    public let sessionID: String
    public let recipient: Recipient
    public let teamID: String
    public let inboxRootDirectory: URL
    public let outcome: WatcherOutcome
    public let pidFileRoot: URL

    private var observerCancellable: TeamInboxObserver.Cancellable?
    private var observer: TeamInboxObserver?
    private var hasFired = false
    /// IDs already on disk when the watcher started; ignored on subsequent
    /// emits. Tracking IDs (rather than a Date watermark) sidesteps the
    /// fact that `TeamInboxMessage.createdAt` is JSON-encoded with second
    /// precision while `Date()` carries sub-second precision — a strict
    /// `createdAt > startedAt` filter would drop messages appended in the
    /// same wall-clock second the watcher booted.
    private var initialIDs: Set<String> = []
    private var sawInitialEmit = false

    public init(
        sessionID: String,
        recipient: Recipient,
        teamID: String,
        inboxRootDirectory: URL,
        outcome: WatcherOutcome,
        pidFileRoot: URL
    ) {
        self.sessionID = sessionID
        self.recipient = recipient
        self.teamID = teamID
        self.inboxRootDirectory = inboxRootDirectory
        self.outcome = outcome
        self.pidFileRoot = pidFileRoot
    }

    /// Park the current task until either the outcome is resolved or the
    /// task is cancelled. Sets up the PID file and observer once.
    public func runUntilSignal() async {
        do {
            try supersedePriorWatcher()
            try writePIDFile()
        } catch {
            await outcome.complete(exitCode: 1, stderr: "watcher setup failed: \(error)\n")
            return
        }

        startObserver()

        // Park until cancellation. The observer callback is what
        // resolves `outcome`; the CLI driver kills the process on its
        // own once that resolves, so we don't need to "exit" from here.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        observerCancellable?.cancel()
        observerCancellable = nil
        observer = nil
    }

    private func startObserver() {
        let obs = TeamInboxObserver(rootDirectory: inboxRootDirectory, teamID: teamID)
        self.observer = obs
        let cancellable = obs.start { [weak self] messages in
            guard let self else { return }
            Task { await self.handle(messages: messages) }
        }
        self.observerCancellable = cancellable
    }

    private func handle(messages: [TeamInboxMessage]) async {
        guard !hasFired else { return }
        // First emit defines the baseline of "already on disk before we
        // started"; we only react to IDs added after that snapshot.
        if !sawInitialEmit {
            sawInitialEmit = true
            initialIDs = Set(messages.map(\.id))
            return
        }
        guard let match = messages.first(where: { msg in
            !initialIDs.contains(msg.id) &&
                msg.to.member == recipient.member &&
                (msg.to.runtime == nil || msg.to.runtime == recipient.runtime.rawValue)
        }) else { return }
        hasFired = true
        await outcome.complete(exitCode: 2, stderr: Self.summary(for: match))
    }

    private static func summary(for message: TeamInboxMessage) -> String {
        let preview = message.body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? message.body
        return "[graftty] new message from \(message.from.member): \(preview)\n"
    }

    private func writePIDFile() throws {
        let path = pidFilePath()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: path, atomically: true, encoding: .utf8)
    }

    private func supersedePriorWatcher() throws {
        let path = pidFilePath()
        guard let priorString = try? String(contentsOf: path, encoding: .utf8),
              let priorPID = Int32(priorString.trimmingCharacters(in: .whitespacesAndNewlines)),
              priorPID > 0,
              priorPID != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        // Already-dead prior is fine; SIGTERM returns -1/ESRCH, ignore.
        _ = kill(priorPID, SIGTERM)
        // Poll up to ~500ms for the prior to actually exit before we
        // overwrite its PID file (avoids races where two watchers think
        // they own the same session).
        for _ in 0..<10 {
            if kill(priorPID, 0) != 0 && errno == ESRCH { break }
            usleep(50_000)
        }
    }

    private func pidFilePath() -> URL {
        pidFileRoot
            .appendingPathComponent(teamID, isDirectory: true)
            .appendingPathComponent("watchers", isDirectory: true)
            .appendingPathComponent("\(sessionID).\(recipient.runtime.rawValue).pid")
    }
}

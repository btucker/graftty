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

/// @spec TEAM-IDLE-1.4
/// @spec TEAM-11.1
/// @spec TEAM-11.4
/// @spec TEAM-11.5
/// @spec TEAM-11.8
/// Long-running watcher used by Claude's `asyncRewake` Stop hook. Writes
/// its own PID to `<pidFileRoot>/<teamID>/watchers/<worktree>.<runtime>.pid`,
/// SIGTERMing whatever PID was previously there (one watcher per worktree
/// and runtime, deterministically — the next Stop firing supersedes the
/// prior watcher even when it belonged to an earlier session). Exits on
/// its poll tick once its original parent process is gone, so watchers
/// cannot outlive their agent session and pile up on the shared inbox
/// lock. Otherwise tails the inbox JSONL via `TeamInboxObserver` and
/// resolves `outcome` with exit-code 2 + a stderr summary the first time
/// a fresh message addressed to its recipient arrives.
public actor InboxWatcher {
    public struct Recipient: Sendable, Equatable {
        public let member: String
        public let worktree: String
        public let runtime: TeamHookRuntime
        public init(member: String, worktree: String, runtime: TeamHookRuntime) {
            self.member = member
            self.worktree = worktree
            self.runtime = runtime
        }
    }

    public let sessionID: String
    public let recipient: Recipient
    /// Canonical agent identity of the session this watcher wakes. Rows
    /// pinned to this exact agent are claimable; rows pinned to any other
    /// agent are left for their own delivery path. A nil identity claims
    /// only unpinned rows.
    public let agentID: String?
    public let teamID: String
    public let inboxRootDirectory: URL
    public let outcome: WatcherOutcome
    public let pidFileRoot: URL
    public let eventLog: TeamEventLog?
    private let pollIntervalNanoseconds: UInt64
    private let watermarkLockTimeout: TimeInterval
    private let parentAliveCheck: @Sendable () -> Bool

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
    private var isReady: Bool = false
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasObservedWatermark = false
    private var observedWatermarkID: String?
    /// TEAM-11.8: set when a claim attempt threw (lock timeout); the next
    /// poll tick retries the claim directly instead of waiting for a
    /// watermark value change that may never come.
    private var claimRetryPending = false

    public init(
        sessionID: String,
        recipient: Recipient,
        agentID: String? = nil,
        teamID: String,
        inboxRootDirectory: URL,
        outcome: WatcherOutcome,
        pidFileRoot: URL,
        eventLog: TeamEventLog? = TeamEventLog.defaultLog(),
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        watermarkLockTimeout: TimeInterval = 2.0,
        parentAliveCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.sessionID = sessionID
        self.recipient = recipient
        self.agentID = agentID
        self.teamID = teamID
        self.inboxRootDirectory = inboxRootDirectory
        self.outcome = outcome
        self.pidFileRoot = pidFileRoot
        self.eventLog = eventLog
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.watermarkLockTimeout = watermarkLockTimeout
        self.parentAliveCheck = parentAliveCheck ?? Self.defaultParentAliveCheck()
    }

    private func makeInbox() -> TeamInbox {
        TeamInbox(
            rootDirectory: inboxRootDirectory,
            watermarkLockTimeout: watermarkLockTimeout
        )
    }

    /// TEAM-11.5: the production liveness probe compares the parent PID
    /// captured at construction against the current one — when the agent
    /// session (our spawner) exits, the watcher is reparented and the
    /// values diverge. PID comparison rather than `kill(pid, 0)` so a
    /// recycled PID can't keep an orphan alive.
    private static func defaultParentAliveCheck() -> @Sendable () -> Bool {
        let originalParent = getppid()
        return { getppid() == originalParent }
    }

    /// Awaits until the watcher has finished startup: PID file written and
    /// the FSEvents observer has fired its initial callback (i.e., it is
    /// actually listening). Resolves immediately if already ready.
    /// Tests use this instead of `Task.sleep` to avoid timing flakiness on
    /// contended CI executors.
    public func whenReady() async {
        if isReady { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyContinuations.append(cont)
        }
    }

    private func markReady() {
        if isReady { return }
        isReady = true
        let pending = readyContinuations
        readyContinuations.removeAll()
        for c in pending { c.resume() }
    }

    /// Park the current task until either the outcome is resolved or the
    /// task is cancelled. Sets up the PID file and observer once.
    public func runUntilSignal() async {
        do {
            try supersedePriorWatcher()
            try writePIDFile()
        } catch {
            await outcome.complete(exitCode: 1, stderr: "watcher setup failed: \(error)\n")
            // Even on setup failure, unblock any whenReady() waiters so
            // tests don't hang indefinitely.
            markReady()
            return
        }

        emit(.watcherSpawned, detail: [
            "session": sessionID,
            "member": recipient.member,
            "worktree": recipient.worktree,
            "runtime": recipient.runtime.rawValue,
        ])

        startObserver()
        captureCurrentWatermark()

        // Park until cancellation. The observer callback is what
        // resolves `outcome`; the CLI driver kills the process on its
        // own once that resolves, so we don't need to "exit" from here.
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            // TEAM-11.5: an orphaned watcher (agent session gone) must not
            // keep polling — lingering watchers convoy on the shared inbox
            // lock and can claim messages no live session will ever see.
            guard parentAliveCheck() else {
                await outcome.complete(exitCode: 0, stderr: "")
                break
            }
            // A different runtime can consume a head-of-line targeted row
            // by advancing the shared watermark without appending to
            // messages.jsonl. Retry while armed so the next eligible row
            // does not wait for an unrelated future append.
            if sawInitialEmit {
                // TEAM-11.8: a claim that failed outright (watermark lock
                // timeout) leaves an obligation the watermark-value gate
                // cannot see — the value may never change again. The latch,
                // not the value edge, carries that obligation.
                if claimRetryPending {
                    claimRetryPending = false
                    await claimAndFire()
                } else {
                    await claimIfWatermarkAdvanced()
                }
            }
        }

        observerCancellable?.cancel()
        observerCancellable = nil
        observer = nil

        emit(.watcherExited, detail: [
            "session": sessionID,
            "runtime": recipient.runtime.rawValue,
        ])
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
            // A message can land after SessionStart advanced this session's
            // cursor but before the Stop watcher attaches. Do not baseline
            // such a message away: the persisted cursor tells us it is new
            // to this session even though it was present in the observer's
            // first snapshot.
            let inbox = makeInbox()
            if (try? inbox.cursor(teamID: teamID, sessionID: sessionID)) != nil {
                await claimAndFire()
            } else {
                // Preserve the historical observer baseline for direct
                // watch-inbox callers that did not run SessionStart. A
                // production Claude session already has a persisted cursor.
                let lastExistingID = messages.last(where: {
                    $0.to.worktree == recipient.worktree
                })?.id
                try? inbox.writeCursor(
                    TeamInboxCursor(
                        sessionID: sessionID,
                        worktree: recipient.worktree,
                        runtime: recipient.runtime.rawValue,
                        lastSeenID: lastExistingID
                    ),
                    teamID: teamID
                )
            }
            // FSEvents has delivered its initial state and any cursor-based
            // catch-up claim is complete. Unblock whenReady() waiters only
            // after both startup phases so tests and callers can reason about
            // watermark-only retries deterministically.
            markReady()
            return
        }
        guard messages.contains(where: { msg in
            !initialIDs.contains(msg.id) &&
                msg.to.worktree == recipient.worktree
        }) else { return }
        await claimAndFire()
    }

    private func claimAndFire() async {
        guard !hasFired else { return }
        let inbox = makeInbox()
        let claimed: TeamInboxMessage?
        do {
            claimed = try inbox.claimNextUnreadMessage(
                teamID: teamID,
                sessionID: sessionID,
                recipientWorktree: recipient.worktree,
                runtime: recipient.runtime.rawValue,
                agentID: agentID
            )
        } catch {
            // TEAM-11.8: distinguish "claim failed" (typically
            // watermarkLockTimeout under a lock convoy) from "nothing to
            // claim". Swallowing the failure would strand an armed watcher:
            // no future append or watermark edge is guaranteed to arrive.
            claimRetryPending = true
            return
        }
        guard let match = claimed else { return }
        hasFired = true
        emit(.watcherWoke, detail: [
            "session": sessionID,
            "runtime": recipient.runtime.rawValue,
            "message_id": match.id,
        ])
        await outcome.complete(exitCode: 2, stderr: Self.summary(for: match))
    }

    private func captureCurrentWatermark() {
        let inbox = makeInbox()
        do {
            observedWatermarkID = try inbox.worktreeWatermark(
                teamID: teamID,
                worktree: recipient.worktree
            )?.lastDeliveredToAnySessionID
            hasObservedWatermark = true
        } catch {
            return
        }
    }

    private func claimIfWatermarkAdvanced() async {
        guard !hasFired else { return }
        let inbox = makeInbox()
        let currentID: String?
        do {
            currentID = try inbox.worktreeWatermark(
                teamID: teamID,
                worktree: recipient.worktree
            )?.lastDeliveredToAnySessionID
        } catch {
            return
        }
        guard hasObservedWatermark else {
            observedWatermarkID = currentID
            hasObservedWatermark = true
            await claimAndFire()
            return
        }
        guard currentID != observedWatermarkID else { return }
        observedWatermarkID = currentID
        await claimAndFire()
    }

    private func emit(_ kind: TeamEvent.Kind, detail: [String: String]) {
        try? eventLog?.append(.init(teamID: teamID, kind: kind, detail: detail))
    }

    private static func summary(for message: TeamInboxMessage) -> String {
        let preview = message.body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? message.body
        return "[graftty] new message from \(message.from.worktree): \(preview)\n"
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
        emit(.watcherSuperseded, detail: [
            "session": sessionID,
            "runtime": recipient.runtime.rawValue,
            "prior_pid": String(priorPID),
        ])
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
        // TEAM-11.4: keyed by worktree + runtime, not session. A session
        // that ends without firing (or is replaced via /clear) leaves its
        // watcher running for up to 24h; the next session's watcher for
        // the same worktree must supersede it or watchers accumulate.
        let leaf = TeamInbox.fileComponent("\(recipient.worktree).\(recipient.runtime.rawValue)") + ".pid"
        return pidFileRoot
            .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
            .appendingPathComponent("watchers", isDirectory: true)
            .appendingPathComponent(leaf)
    }
}

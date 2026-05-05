import Foundation

/// Pluggable target for `IdleDeliveryService` nudges. Production wires this
/// to a zmx-send keystroke writer; tests record invocations.
public protocol NudgeSender: Sendable {
    func send(to recipient: TeamPresenceRecord, message: String, messageIDs: [String]) async
}

/// Resolves the zmx session names that host `(worktree, runtime)` for the
/// uncommitted-typed-byte gate. Production injects a closure backed by
/// `AppState` (each running worktree's pane leaves -> `ZmxLauncher.sessionName`);
/// tests inject a stub that returns a single deterministic key (typically
/// the worktree name) so they can drive the gate via the same lookup.
public typealias SessionLookup = @Sendable (TeamPresenceRecord) -> [String]

/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.3
/// Background poller that ticks every `pollInterval` seconds, finds
/// registered Codex agents whose inbox holds unread messages older than
/// `staleAgeThreshold`, and nudges them via `NudgeSender` — gated on
/// (a) the typing state for any zmx session hosting the recipient and
/// (b) once-per-stale-state debounce keyed on the most recent stale ID.
public actor IdleDeliveryService {
    /// A message must sit unread this long before it counts as stale.
    public static let staleAgeThreshold: TimeInterval = 60
    /// Default cadence for `startPolling()`. Tests drive `tick()` directly.
    public static let pollInterval: TimeInterval = 10

    private let presence: TeamPresenceStorage
    private let inboxRoot: URL
    private let inputState: ZmxInputState
    private let nudgeSender: NudgeSender
    private let sessionLookup: SessionLookup
    private let now: @Sendable () -> Date

    /// Per-recipient memory of "the most recent stale message ID we
    /// already nudged about". A new tick that observes the same head
    /// no-ops; a tick that sees a *new* head (more messages arrived) or a
    /// drained inbox followed by a fresh stale message fires again.
    private var lastNudgedHead: [String: String] = [:]

    public init(
        presence: TeamPresenceStorage,
        inboxRoot: URL,
        inputState: ZmxInputState,
        nudgeSender: NudgeSender,
        sessionLookup: SessionLookup? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.presence = presence
        self.inboxRoot = inboxRoot
        self.inputState = inputState
        self.nudgeSender = nudgeSender
        // Default lookup: use the worktree name as the session key. Suits
        // tests (which drive the input-state through that same key) and
        // is a safe-but-imperfect production fallback until the WebSession
        // sessionName plumbing surfaces a real (worktree, runtime) → [pane
        // session] map.
        self.sessionLookup = sessionLookup ?? { record in [record.worktree] }
        self.now = now
    }

    /// Loop forever, ticking on a fixed cadence. Cancellation breaks the
    /// loop. The app boot path runs this in a detached task.
    public func startPolling() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    /// One pass over every registered Codex agent. All I/O failures are
    /// swallowed so a single corrupt presence file doesn't poison the loop.
    public func tick() async {
        let records = (try? presence.listAll()) ?? []
        for record in records where record.runtime == .codex {
            await processOne(record)
        }
    }

    private func processOne(_ record: TeamPresenceRecord) async {
        let inbox = TeamInbox(rootDirectory: inboxRoot)
        let messages = (try? inbox.messages(teamID: record.teamID)) ?? []
        // TEAM-IDLE-2.1: only messages addressed to this worktree, with a
        // matching runtime tag (or no runtime tag at all — system events).
        let forRecipient = messages.filter { msg in
            guard msg.to.worktree == record.worktree else { return false }
            if let runtime = msg.to.runtime, runtime != record.runtime.rawValue {
                return false
            }
            return true
        }
        let cutoff = now().addingTimeInterval(-Self.staleAgeThreshold)
        let stale = forRecipient.filter { $0.createdAt <= cutoff }
        guard let head = stale.last else { return }

        // TEAM-IDLE-2.3: dedupe on the head ID — one nudge per stale-state.
        let key = "\(record.teamID)/\(record.worktree)/\(record.runtime.rawValue)"
        if lastNudgedHead[key] == head.id { return }

        // TEAM-IDLE-2.2: typing gate. Skip if any session hosting this
        // recipient is mid-line. Don't update lastNudgedHead — we want to
        // retry on the next tick once the user commits the line.
        for sessionID in sessionLookup(record) {
            if inputState.uncommittedBytes(forSession: sessionID) > 0 { return }
        }

        let body = Self.renderBody(stale: stale)
        await nudgeSender.send(to: record, message: body, messageIDs: stale.map(\.id))
        lastNudgedHead[key] = head.id
    }

    private static func renderBody(stale: [TeamInboxMessage]) -> String {
        var seen = Set<String>()
        let senders = stale
            .map(\.from.member)
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
        let count = stale.count
        let pluralS = count == 1 ? "" : "s"
        return "[graftty] You have \(count) unread team message\(pluralS) from \(senders). Run `graftty team inbox` to read."
    }
}

/// Production `NudgeSender` placeholder. Logs the nudge but does not yet
/// write keystrokes — the actual zmx-send plumbing (writing to the Codex
/// pane's PTY master fd) is a follow-up. The `IdleDeliveryService` gating
/// logic is wired and tested; this class just stubs the I/O side until the
/// shared writer surfaces a public API the service can call.
public final class ZmxNudgeSender: NudgeSender {
    public init() {}

    public func send(to recipient: TeamPresenceRecord, message: String, messageIDs: [String]) async {
        NSLog("[Graftty] idle-delivery nudge pending for %@.%@: %@",
              recipient.worktree,
              recipient.runtime.rawValue,
              message)
    }
}

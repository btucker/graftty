import Foundation

/// Per-key dispatch bookkeeping shared by the recurring polling stores
/// (`WorktreeStatsStore`, `PRStatusStore`, `RemoteBranchStore`). Keys are
/// repository or worktree paths.
///
/// Each key owns one slot. `inFlightSince` doubles as the abandoned-work
/// detector: a dispatch older than `abandonmentThreshold` no longer
/// suppresses fresh work, because a subprocess wedged on a lock or across
/// sleep/wake may never reach the code that releases its slot (DIVERGE-4.4,
/// DIVERGE-4.11, PR-7.13, GIT-2.12). `generation` is the ownership token:
/// every claim or invalidation assigns a new one, so superseded work skips
/// its permit and its late results are dropped (DIVERGE-4.5, PR-8.17).
/// Generations are unique across all keys and never reused, so work that
/// outlives a `prune` cannot match a later claim for the same key.
///
/// Stores keep their domain logic (what runs, how results apply, trailing
/// reruns, forced pulses) and use this type only for the slot decisions.
@MainActor
final class RepoPollScheduler {

    struct Slot {
        var inFlightSince: Date?
        /// When the most recent dispatch finished, successfully or not.
        var lastCompletion: Date?
        var failureStreak = 0
        var generation = 0
    }

    /// Past this age an in-flight dispatch is treated as abandoned. A normal
    /// git or host CLI pipeline finishes in seconds; the subprocess deadlines
    /// the stores use (20 s) sit below this so a hung child is normally
    /// terminated before it has to be superseded.
    nonisolated static let abandonmentThreshold: Duration = .seconds(30)

    /// Upper bound on dispatches a single polling tick starts. Event-driven
    /// refreshes are the prompt path; recurring polls only repair missed
    /// events, so they visit a bounded batch per tick.
    let batchSize: Int

    private let limiter: BackgroundProcessLimiter
    private let cadence: (_ failureStreak: Int) -> Duration
    private let now: () -> Date
    private var slots: [String: Slot] = [:]
    private var lastGeneration = 0
    /// The store this scheduler works for. Queued work is skipped once the
    /// store is gone, matching the stores' former permit-time `guard let self`.
    private weak var owner: AnyObject?
    private var hasOwner = false
    private var cursor = RoundRobinBatchCursor()

    /// - Parameters:
    ///   - limiter: Shared permit pool bounding concurrent pipelines.
    ///   - batchSize: Maximum dispatches a polling tick starts.
    ///   - cadence: Minimum interval between completed dispatches for a key,
    ///     given its consecutive failure count. Stores without a cadence gate
    ///     leave the default.
    ///   - now: Clock seam for tests.
    init(
        limiter: BackgroundProcessLimiter,
        batchSize: Int = 4,
        cadence: @escaping (_ failureStreak: Int) -> Duration = { _ in .zero },
        now: @escaping () -> Date = Date.init
    ) {
        self.limiter = limiter
        self.batchSize = batchSize
        self.cadence = cadence
        self.now = now
    }

    /// Ties queued work to `owner`'s lifetime: work that obtains a permit
    /// after `owner` is deallocated is skipped. Stores call this once from
    /// their initializer.
    func bind(owner: AnyObject) {
        self.owner = owner
        hasOwner = true
    }

    // MARK: - Slot state

    func generation(_ key: String) -> Int {
        slots[key]?.generation ?? 0
    }

    func failureStreak(_ key: String) -> Int {
        slots[key]?.failureStreak ?? 0
    }

    /// True while a dispatch holds the slot, including an abandoned one.
    func isInFlight(_ key: String) -> Bool {
        slots[key]?.inFlightSince != nil
    }

    /// True while a dispatch holds the slot and is younger than
    /// `abandonmentThreshold`.
    func isLive(_ key: String) -> Bool {
        guard let started = slots[key]?.inFlightSince else { return false }
        return Self.isLive(startedAt: started, now: now())
    }

    func liveKeys() -> Set<String> {
        let now = now()
        return Set(slots.compactMap { key, slot in
            guard let started = slot.inFlightSince,
                  Self.isLive(startedAt: started, now: now) else { return nil }
            return key
        })
    }

    /// Dispatch budget left for a polling tick after live work is counted.
    func availableDispatchSlots() -> Int {
        max(0, batchSize - liveKeys().count)
    }

    /// True while the key's last completion is within the cadence for its
    /// failure streak. Keys that never completed are due.
    func isCoolingDown(_ key: String) -> Bool {
        guard let slot = slots[key], let last = slot.lastCompletion else { return false }
        return now().timeIntervalSince(last) < Self.seconds(cadence(slot.failureStreak))
    }

    func isCurrent(_ key: String, generation: Int) -> Bool {
        slots[key]?.generation == generation
    }

    // MARK: - Transitions

    /// Marks the key in flight and returns the new ownership generation.
    /// Any earlier dispatch for the key is superseded.
    func claim(_ key: String) -> Int {
        let generation = nextGeneration()
        slots[key, default: Slot()].inFlightSince = now()
        slots[key, default: Slot()].generation = generation
        return generation
    }

    /// Releases the slot and supersedes any running dispatch, so a later
    /// request is not suppressed while the old work drains and the old
    /// work's late result is dropped.
    func invalidate(_ key: String) {
        let generation = nextGeneration()
        slots[key, default: Slot()].inFlightSince = nil
        slots[key, default: Slot()].generation = generation
    }

    private func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }

    /// Releases the slot if `generation` still owns it. Returns whether it
    /// did, which is also whether the caller's result is still current.
    @discardableResult
    func release(_ key: String, generation: Int) -> Bool {
        guard isCurrent(key, generation: generation) else { return false }
        slots[key]?.inFlightSince = nil
        return true
    }

    func recordSuccess(_ key: String) {
        slots[key, default: Slot()].lastCompletion = now()
        slots[key, default: Slot()].failureStreak = 0
    }

    func recordFailure(_ key: String) {
        slots[key, default: Slot()].lastCompletion = now()
        slots[key, default: Slot()].failureStreak += 1
    }

    /// Records a completion that neither succeeded nor failed (for example,
    /// an unsupported hosting provider): the cadence restarts and the
    /// failure streak is unchanged.
    func recordCompletion(_ key: String) {
        slots[key, default: Slot()].lastCompletion = now()
    }

    /// Drops slots for keys no longer in the model so bookkeeping does not
    /// grow across a long session.
    func prune(keeping keys: Set<String>) {
        for key in slots.keys where !keys.contains(key) {
            slots.removeValue(forKey: key)
        }
    }

    // MARK: - Dispatch

    /// Round-robin batch of at most `maximumCount` (default `batchSize`)
    /// candidates, rotating fairly across ticks.
    func nextBatch<Element>(
        from candidates: [Element],
        maximumCount: Int? = nil,
        path: (Element) -> String
    ) -> [Element] {
        cursor.nextBatch(
            from: candidates,
            maximumCount: maximumCount ?? batchSize,
            path: path
        )
    }

    /// Runs `work` under a limiter permit if `generation` still owns the key
    /// once the permit is obtained; returns nil without running it otherwise.
    /// The in-flight timestamp restarts when the permit is obtained so the
    /// work gets its full abandonment window rather than counting time spent
    /// queued behind other pollers.
    func run<T: Sendable>(
        _ key: String,
        generation: Int,
        _ work: @Sendable () async throws -> T
    ) async rethrows -> T? {
        try await limiter.run { [weak self] in
            guard let self,
                  await self.begin(key, generation: generation) else { return nil }
            return try await work()
        }
    }

    private func begin(_ key: String, generation: Int) -> Bool {
        guard !hasOwner || owner != nil,
              isCurrent(key, generation: generation) else { return false }
        slots[key]?.inFlightSince = now()
        return true
    }

    private nonisolated static func isLive(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) < seconds(abandonmentThreshold)
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    // MARK: - Test seams

    /// Simulates a dispatch that started at `date` without bumping the
    /// generation, matching how the stores' tests seed hung work.
    func seedInFlightForTesting(_ key: String, since date: Date) {
        slots[key, default: Slot()].inFlightSince = date
    }

    func seedLastCompletionForTesting(_ key: String, at date: Date) {
        slots[key, default: Slot()].lastCompletion = date
    }
}

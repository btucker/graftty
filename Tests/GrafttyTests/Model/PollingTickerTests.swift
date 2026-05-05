import Foundation
import Testing
@testable import Graftty

/// Liveness regression tests for `PollingTicker`. The original
/// failure mode was the loop firing one initial tick and then
/// stalling forever — only the on-demand `refresh()` path produced
/// fresh data, observable as "PR / stats status only updates when I
/// click on a worktree tab". `PR-7.13` / `PR-7.14` covered tickers
/// that were alive but failing; this suite covers the case where
/// the ticker itself stops running.
@MainActor
@Suite("""
PollingTicker liveness

@spec PR-8.10: The polling ticker shall keep firing `onTick` on its configured interval indefinitely, without stalling after one or more sleep / pulse cycles. `pulse()` shall cause the next tick to fire ahead of schedule, with bounded latency, rather than waiting for the full interval.
""", .serialized)
struct PollingTickerTests {

    /// Multiple ticks must fire over time without external pulses —
    /// the loop has to keep itself alive between sleep cycles.
    @Test
    func tickFiresMultipleTimesWithoutPulse() async throws {
        let counter = TickCounter()
        let ticker = PollingTicker(
            interval: .milliseconds(40),
            pauseWhenInactive: { false }
        )
        ticker.start { await counter.increment() }
        defer { ticker.stop() }

        // Liveness, not cadence: ≥2 falsifies the "fires once then
        // stalls forever" regression. Strict cadence isn't asserted —
        // a loaded scheduler can stretch any specific tick budget.
        let deadline = Date().addingTimeInterval(10.0)
        while await counter.value < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let count = await counter.value
        #expect(count >= 2, "expected ≥2 ticks within 10s; got \(count) (loop must keep firing between sleep cycles)")
    }

    /// `pulse()` cancels the active sleep and the loop fires the
    /// next tick immediately. Without this, the only way to wake
    /// the ticker early would be to wait for the full interval.
    @Test
    func pulseFiresNextTickEarly() async throws {
        let counter = TickCounter()
        let ticker = PollingTicker(
            // Long enough that an unpulsed second tick can't land
            // within the test window — only `pulse()` can produce one.
            interval: .seconds(5),
            pauseWhenInactive: { false }
        )
        ticker.start { await counter.increment() }
        defer { ticker.stop() }

        // Wait for the initial tick to fire and the loop to enter
        // its sleep phase.
        for _ in 0..<50 {
            if await counter.value >= 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value == 1, "initial tick should have fired")

        ticker.pulse()

        // The pulse cancels the in-progress sleep; the next tick
        // should land within a few ms, well under the 5-second
        // interval.
        for _ in 0..<100 {
            if await counter.value >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.value >= 2, "pulse should produce a second tick")
    }

    /// Many pulse-and-sleep cycles in succession must not stall the
    /// loop. The previous implementation leaked one pulse-iterator
    /// Task per iteration; the deadlock surfaced after the first
    /// sleep-wins iteration. This test exercises the cycle
    /// sufficiently that any "one-iteration-then-stuck" regression
    /// would fail it.
    @Test
    func surviveManyPulseSleepCycles() async throws {
        let counter = TickCounter()
        let ticker = PollingTicker(
            interval: .milliseconds(50),
            pauseWhenInactive: { false }
        )
        ticker.start { await counter.increment() }
        defer { ticker.stop() }

        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(15))
            ticker.pulse()
        }

        // Wait a beat for the trailing ticks to land.
        try await Task.sleep(for: .milliseconds(80))

        let count = await counter.value
        #expect(count >= 5, "expected the loop to survive multiple pulse cycles; got \(count) ticks")
    }
}

actor TickCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

#if canImport(UIKit)
import Foundation

/// Stands in for the held-arrow repeat timer: nothing repeats until the test
/// calls `fire()`, so IOS-6.28 needs no wall-clock sleeps (#620).
@MainActor
final class ManualArrowRepeat {
    private(set) var initialDelay: TimeInterval = 0
    private(set) var interval: TimeInterval = 0
    private var tick: (@MainActor () -> Bool)?
    private var generation = 0

    var isRepeating: Bool { tick != nil }

    func start(initialDelay: TimeInterval, interval: TimeInterval,
               tick: @escaping @MainActor () -> Bool) -> () -> Void {
        self.initialDelay = initialDelay
        self.interval = interval
        generation += 1
        let started = generation
        self.tick = tick
        return { [weak self] in
            guard let self, self.generation == started else { return }
            self.tick = nil
        }
    }

    /// Runs one repeat, as the timer would after the initial delay.
    func fire() {
        guard let tick else { return }
        if !tick() { self.tick = nil }
    }
}

#endif

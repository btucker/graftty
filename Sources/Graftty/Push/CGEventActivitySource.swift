import AppKit
import CoreGraphics
import GrafttyKit

/// Production `DesktopActivitySource`. Observes screen lock/unlock,
/// sleep/wake, and refreshes a cached "last input age" via
/// `CGEventSource.secondsSinceLastEventType` on a 5s timer. The cached
/// values are read synchronously by `DesktopActivityMonitor` so the
/// AttentionPushDecider doesn't have to await an actor hop while
/// deciding whether to fan out a push.
@MainActor
final class CGEventActivitySource: @MainActor DesktopActivitySource {
    private(set) var systemAsleep = false
    private(set) var screenLocked = false
    private(set) var lastInputAgeSeconds: TimeInterval = 0
    private var timer: Timer?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(screenLockedNote),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(screenUnlockedNote),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIdle() }
        }
        refreshIdle()
    }

    @objc private func willSleep() { systemAsleep = true }
    @objc private func didWake() {
        systemAsleep = false
        refreshIdle()
    }
    @objc private func screenLockedNote() { screenLocked = true }
    @objc private func screenUnlockedNote() { screenLocked = false }

    private func refreshIdle() {
        // CGEventType(rawValue: ~0) is the documented "any event" sentinel —
        // Apple's headers reference it as `kCGAnyInputEventType` but it isn't
        // bridged into Swift's enum, so the rawValue dance is the path the
        // platform takes. The initializer is guaranteed non-nil for this
        // raw value, so the force-unwrap is safe.
        lastInputAgeSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }
}

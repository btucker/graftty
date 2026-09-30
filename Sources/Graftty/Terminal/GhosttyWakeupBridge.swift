import Foundation

/// Registers the notification-to-tick boundary used by TerminalManager.
enum GhosttyWakeupBridge {
    static func observe(
        center: NotificationCenter = .default,
        tick: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        // A main-thread wakeup can arrive while libghostty holds its renderer
        // mutex. Even on main, tick must wait until that callback unwinds.
        // queue: nil also avoids making a background poster wait for main.
        center.addObserver(forName: .ghosttyWakeup, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                tick()
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main thread whenever libghostty's wakeup callback fires.
    /// Observers must defer `GhosttyApp.tick()` until the posting stack unwinds.
    static let ghosttyWakeup = Notification.Name("com.graftty.ghostty.wakeup")
}

import Foundation

public protocol DesktopActivitySource: AnyObject {
    var systemAsleep: Bool { get }
    var screenLocked: Bool { get }
    var lastInputAgeSeconds: TimeInterval { get }
}

public final class DesktopActivityMonitor: @unchecked Sendable {
    private let source: DesktopActivitySource

    public init(source: DesktopActivitySource) {
        self.source = source
    }

    /// True iff the Mac is awake, unlocked, and the user has interacted
    /// with the system within the last 60 seconds.
    public var isUserActiveOnDesktop: Bool {
        !source.systemAsleep && !source.screenLocked && source.lastInputAgeSeconds < 60
    }
}

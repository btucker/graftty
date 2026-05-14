#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI

public struct GrafttyMobileApp: App {
    /// SwiftUI installs this delegate before the first `Scene` body runs;
    /// `PushAppDelegate.init` constructs `PushRegistrar` against the shared
    /// `HostStore` so APNs callbacks are wired before iOS can deliver them.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate

    public init() {
        UITerminalView.suppressGhosttyInputAccessory()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
#endif

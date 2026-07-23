#if canImport(UIKit)
import SwiftUI

public struct GrafttyMobileApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands {
            CommandGroup(after: .textEditing) {
                MobileGhosttyCommandButtons()
            }
        }
    }
}
#endif

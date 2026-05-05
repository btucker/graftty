#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI

public struct GrafttyMobileApp: App {
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

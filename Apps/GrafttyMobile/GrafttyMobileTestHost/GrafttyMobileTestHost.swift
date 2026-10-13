import SwiftUI

// UIKit and WebKit integration tests need UIApplicationMain and foreground
// events, without starting production pairing, session, or biometric state.
@main
struct GrafttyMobileTestHost: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}

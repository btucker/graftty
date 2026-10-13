import SwiftUI
#if GRAFTTY_BROWSER_CONTROL_FIXTURE
@testable import GrafttyMobileKit
#endif

// UIKit and WebKit integration tests need UIApplicationMain and foreground
// events, without starting production pairing, session, or biometric state.
@main
struct GrafttyMobileTestHost: App {
    var body: some Scene {
        WindowGroup {
            #if GRAFTTY_BROWSER_CONTROL_FIXTURE
            BrowserControlFixture()
            #else
            Color.clear
            #endif
        }
    }
}

#if GRAFTTY_BROWSER_CONTROL_FIXTURE
private struct BrowserControlFixture: View {
    @State private var activated = false
    var body: some View {
        VStack(spacing: 24) {
            RemoteOpenButton.floatingControl(availableCount: 1, isBusy: false) { activated = true }
                .padding(14)
            Text(activated ? "Activated" : "Idle")
        }
        .preferredColorScheme(.light)
    }
}

#endif

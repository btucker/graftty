import GrafttyMobileKit
import SwiftUI

@main
struct GrafttyMobileEntry: App {
    // Install the notification delegate before application launch finishes.
    private let mobileApp = GrafttyMobileApp()

    var body: some Scene {
        mobileApp.body
    }
}

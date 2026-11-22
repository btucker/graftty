import GrafttyWatchKit
import SwiftUI

@main
struct GrafttyWatchApp: App {
    @State private var connection = WatchPhoneConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchInboxView(connection: connection)
                .task { connection.activate() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    connection.setActive(phase == .active)
                }
        }
        .backgroundTask(.watchConnectivity) { await connection.receiveBackgroundUpdate() }
    }
}

import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("Display ownership assembly")
struct DisplayOwnershipAssemblyTests {
    @Test
    func terminalManagerExposesInjectedDisplayOwnershipStoreIdentity() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-display-ownership-a.sock")
        let store = SessionDisplayOwnershipStore()

        manager.displayOwnershipStore = store

        #expect(manager.displayOwnershipStore === store)
    }

    @Test
    func isolatedTerminalManagersCanUseDifferentOwnershipStores() throws {
        let firstManager = TerminalManager(socketPath: "/tmp/graftty-display-ownership-b.sock")
        let secondManager = TerminalManager(socketPath: "/tmp/graftty-display-ownership-c.sock")
        let firstStore = SessionDisplayOwnershipStore()
        let secondStore = SessionDisplayOwnershipStore()
        firstManager.displayOwnershipStore = firstStore
        secondManager.displayOwnershipStore = secondStore

        // Attach no longer implicitly claims ownership; claim explicitly so each
        // store holds an independent owner for the isolation assertions below.
        _ = firstManager.displayOwnershipStore?.attachClient(
            sessionName: "shared-session-name",
            clientID: DisplayClientID("mac-client"),
            kind: .mac,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 80, rows: 24)
        )
        _ = firstManager.displayOwnershipStore?.claimOwner(
            sessionName: "shared-session-name",
            clientID: DisplayClientID("mac-client"),
            kind: .mac,
            grid: try DisplayGrid(cols: 80, rows: 24)
        )
        _ = secondManager.displayOwnershipStore?.attachClient(
            sessionName: "shared-session-name",
            clientID: DisplayClientID("web-client"),
            kind: .web,
            role: .interactive,
            visible: true,
            grid: try DisplayGrid(cols: 100, rows: 30)
        )
        _ = secondManager.displayOwnershipStore?.claimOwner(
            sessionName: "shared-session-name",
            clientID: DisplayClientID("web-client"),
            kind: .web,
            grid: try DisplayGrid(cols: 100, rows: 30)
        )

        #expect(firstManager.displayOwnershipStore?.snapshot(sessionName: "shared-session-name").ownerClientID == DisplayClientID("mac-client"))
        #expect(secondManager.displayOwnershipStore?.snapshot(sessionName: "shared-session-name").ownerClientID == DisplayClientID("web-client"))
        #expect(firstManager.displayOwnershipStore !== secondManager.displayOwnershipStore)
    }

    @Test
    func webServerControllerRetainsInjectedDisplayOwnershipStoreIdentity() {
        let previousEnabled = UserDefaults.standard.object(forKey: "WebAccessEnabled")
        defer {
            if let previousEnabled {
                UserDefaults.standard.set(previousEnabled, forKey: "WebAccessEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "WebAccessEnabled")
            }
        }
        UserDefaults.standard.set(false, forKey: "WebAccessEnabled")
        let injected = SessionDisplayOwnershipStore()
        let replacement = SessionDisplayOwnershipStore()
        let controller = WebServerController(
            settings: WebAccessSettings(),
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            displayOwnershipStore: injected
        )

        #expect(controller.displayOwnershipStoreForTests === injected)

        controller.setDisplayOwnershipStore(replacement)

        #expect(controller.displayOwnershipStoreForTests === replacement)
    }
}

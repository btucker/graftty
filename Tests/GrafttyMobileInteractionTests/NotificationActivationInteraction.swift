import Foundation
import UIKit
import XCTest

extension AgentNativeInteractionTests {
    /// Native alerts must enter through the installed notification delegate;
    /// assigning pendingRoute here would bypass the launch failure under test.
    @MainActor
    func performNotificationGesture(_ command: AgentIntegrationCommand, app: XCUIApplication) throws -> [String: String] {
        defer {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "notification-action-\(command.id)-\(command.operation)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        var result = ["performed": command.operation]
        if command.operation == "notificationsBack" {
            let back = app.buttons["Back to worktrees"]
            guard back.waitForExistence(timeout: 5) else { throw AgentIntegrationError("notification terminal Back missing") }
            back.tap()
            guard app.otherElements["Agent integration terminal"].waitForNonExistence(timeout: 5) else {
                throw AgentIntegrationError("notification terminal stayed mounted after Back")
            }
            return ["performed": command.operation, "terminalDetached": "true"]
        } else if command.operation == "notificationsCapture" {
            guard app.state == .runningForeground,
                  app.staticTexts["Notification activation selection"].exists else {
                throw AgentIntegrationError("Cannot capture notification terminal without foreground production RootView")
            }
            return ["performed": command.operation, "foreground": "true", "rootVisible": "true"]
        } else if command.operation == "notificationsDismissError" {
            let alert = app.alerts["Could not open notification"]
            guard alert.waitForExistence(timeout: 10) else {
                throw AgentIntegrationError("Production RootView did not show the expected notification activation error")
            }
            let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "notification-error-\(command.id)"
            attachment.lifetime = .keepAlways
            add(attachment)
            alert.buttons["OK"].tap()
            return ["performed": command.operation, "errorTitle": "Could not open notification", "errorMessage": message]
        } else if command.operation == "notificationsAuthorize" {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let permission = springboard.alerts.containing(.staticText,
                identifier: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.").firstMatch
            if permission.waitForExistence(timeout: 5) {
                let allow = permission.buttons["Allow"]
                for _ in 0..<2 {
                    guard allow.waitForExistence(timeout: 2), allow.isHittable else { break }
                    allow.tap()
                    if permission.waitForNonExistence(timeout: 5) { break }
                }
                guard permission.waitForNonExistence(timeout: 2) else {
                    throw AgentIntegrationError("Notification authorization prompt stayed visible after Allow")
                }
            }
            return ["performed": command.operation]
        } else if command.operation == "notificationsNavigate" {
            let button = app.buttons["Notification choose unrelated pane"]
            guard button.waitForExistence(timeout: 5) else {
                throw AgentIntegrationError("Notification fixture navigation control did not appear")
            }
            button.tap()
        } else {
            let lifecycle = command.parameters["lifecycle"] ?? "warm"
            let title = try XCTUnwrap(command.parameters["title"])
            if lifecycle == "cold" { app.terminate() }
            else if lifecycle == "background" { XCUIDevice.shared.press(.home) }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let banner = springboard.staticTexts[title].firstMatch
            var usedNotificationCenter = false
            // Warm fixtures schedule the original request after this native
            // worker is ready. A foreground banner need not persist in the
            // Notification Center list; catch it while it is actually visible.
            if !banner.waitForExistence(timeout: lifecycle == "warm" ? 10 : 2) {
                // Open Notification Center for a delivered alert whose banner
                // expired. The same gesture works from the app and Home screen.
                let screen = springboard.frame
                let start = springboard.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: screen.midX, dy: 1))
                let end = start.withOffset(CGVector(dx: 0, dy: screen.height * 0.75))
                start.press(forDuration: 0.05, thenDragTo: end)
                usedNotificationCenter = true
            }
            if usedNotificationCenter {
                // Foreground alerts can already be in notification history,
                // below the cover sheet's incoming page. Drag within the lower
                // notification list; its empty background can leave it collapsed.
                for attempt in 1...3 {
                    if banner.waitForExistence(timeout: 2) { break }
                    let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                    let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                    start.press(forDuration: 0.05, thenDragTo: end)
                    result["notificationHistorySwipes"] = String(attempt)
                    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    attachment.name = "notification-history-\(command.id)-\(attempt)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            guard banner.waitForExistence(timeout: 10) else {
                let hierarchy = XCTAttachment(string: springboard.debugDescription)
                hierarchy.name = "notification-center-hierarchy-\(command.id)"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                throw AgentIntegrationError("Native notification '\(title)' did not appear in Simulator Notification Center")
            }
            banner.tap()
            var tapCount = 1
            var swipeCount = 0
            var tappedOpen = false
            // On the collapsed incoming page, Notification Center consumes the
            // first tap to reveal the list. A second tap can only show a swipe
            // hint, so follow the native swipe-to-open interaction on that same
            // notification. Never launch the app or synthesize its route here.
            if usedNotificationCenter, !app.wait(for: .runningForeground, timeout: 2) {
                let revealed = springboard.staticTexts[title].firstMatch
                if revealed.exists, revealed.isHittable {
                    revealed.swipeRight()
                    swipeCount += 1
                    let swipeAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    swipeAttachment.name = "notification-after-swipe-\(command.id)"
                    swipeAttachment.lifetime = .keepAlways
                    add(swipeAttachment)
                    if !app.wait(for: .runningForeground, timeout: 2) {
                        let open = springboard.buttons["Open"].firstMatch
                        if open.waitForExistence(timeout: 2), open.isHittable {
                            open.tap()
                            tapCount += 1
                            tappedOpen = true
                        }
                    }
                }
            }
            guard app.wait(for: .runningForeground, timeout: 10) else {
                throw AgentIntegrationError("Native notification did not foreground the app after \(tapCount) tap(s), \(swipeCount) right swipe(s); tappedOpen=\(tappedOpen), notificationCenter=\(usedNotificationCenter), appState=\(app.state.rawValue)")
            }
            guard app.staticTexts["Notification activation selection"].waitForExistence(timeout: 10) else {
                throw AgentIntegrationError("Native notification foregrounded the app but the production RootView fixture did not appear")
            }
            result["tapCount"] = String(tapCount)
            result["swipeCount"] = String(swipeCount)
            result["tappedOpen"] = String(tappedOpen)
            result["usedNotificationCenter"] = String(usedNotificationCenter)
            result["foreground"] = "true"
            result["rootVisible"] = "true"
        }
        return result
    }
}

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
        if command.operation == "notificationsDismissError" {
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
            let allow = springboard.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
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
            if !banner.waitForExistence(timeout: 2) {
                // Open Notification Center for a delivered alert whose banner
                // expired. The same gesture works from the app and Home screen.
                let screen = springboard.frame
                let start = springboard.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: screen.midX, dy: 1))
                let end = start.withOffset(CGVector(dx: 0, dy: screen.height * 0.75))
                start.press(forDuration: 0.05, thenDragTo: end)
                usedNotificationCenter = true
            }
            guard banner.waitForExistence(timeout: 10) else {
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

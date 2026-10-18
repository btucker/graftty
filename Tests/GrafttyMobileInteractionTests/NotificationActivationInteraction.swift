import Foundation
import UIKit
import XCTest

extension AgentNativeInteractionTests {
    /// Native alerts must enter through the installed notification delegate;
    /// assigning pendingRoute here would bypass the launch failure under test.
    @MainActor
    func performNotificationGesture(_ command: AgentIntegrationCommand, app: XCUIApplication) throws -> [String: String] {
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
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        } else {
            let lifecycle = command.parameters["lifecycle"] ?? "warm"
            let title = try XCTUnwrap(command.parameters["title"])
            if lifecycle == "cold" { app.terminate() }
            else if lifecycle == "background" { XCUIDevice.shared.press(.home) }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let banner = springboard.staticTexts[title].firstMatch
            if !banner.waitForExistence(timeout: 2) {
                // Open Notification Center for a delivered alert whose banner
                // expired. The same gesture works from the app and Home screen.
                let screen = springboard.frame
                let start = springboard.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: screen.midX, dy: 1))
                let end = start.withOffset(CGVector(dx: 0, dy: screen.height * 0.75))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            guard banner.waitForExistence(timeout: 10) else {
                throw AgentIntegrationError("Native notification '\(title)' did not appear in Simulator Notification Center")
            }
            banner.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(app.staticTexts["Notification activation selection"].waitForExistence(timeout: 10))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "notification-action-\(command.id)-\(command.operation)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return ["performed": command.operation]
    }
}

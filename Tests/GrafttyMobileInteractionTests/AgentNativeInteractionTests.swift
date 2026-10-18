import Foundation
import UIKit
import XCTest

@MainActor
final class AgentNativeInteractionTests: XCTestCase {
    /// @spec TEST-1.5: When a scripted native integration run requests mobile gestures or notification taps, the test harness shall drive XCUITest, preserve screenshots with the action sequence ID, and reject notification tap success unless the application is foregrounded and its activation view is visible.
    func testScriptedAgentInteractions() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["GRAFTTY_AGENT_INTEGRATION_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Run scripts/agent-integration/run.py to supply the isolated controller")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--agent-integration-url", endpoint.absoluteString]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let transport = AgentIntegrationTransport(endpoint: endpoint, client: "gestures")
        try await transport.register(["driver": "XCUITest"])
        try await transport.run { command in
            let terminal = app.otherElements["Agent integration terminal"]
            if command.operation == "finish" { return [:] }
            if ["notificationsTap", "notificationsNavigate", "notificationsAuthorize", "notificationsDismissError"].contains(command.operation) {
                return try self.performNotificationGesture(command, app: app)
            }
            XCTAssertTrue(terminal.waitForExistence(timeout: 15))
            switch command.operation {
            case "resize":
                let wide = (Double(command.parameters["width"] ?? "0") ?? 0) > (Double(command.parameters["height"] ?? "0") ?? 0)
                XCUIDevice.shared.orientation = wide ? .landscapeLeft : .portrait
            case "scroll":
                if command.parameters["position"] == "bottom" { terminal.swipeUp(velocity: .fast) }
                else {
                    let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
                }
            case "keyboard":
                let visible = command.parameters["visible"] == "true"
                if visible { app.buttons["Agent integration show keyboard"].tap() }
                else if command.parameters["attempt"] == "true" { terminal.tap() }
                else { app.buttons["Agent integration dismiss keyboard"].tap() }
                if visible { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)) }
                else { XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5)) }
            case "snapshot": break
            default: throw AgentIntegrationError("unsupported gesture action \(command.operation)")
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "agent-action-\(command.id)-\(command.provider)-\(command.operation)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            return ["performed": command.operation]
        }
    }
}

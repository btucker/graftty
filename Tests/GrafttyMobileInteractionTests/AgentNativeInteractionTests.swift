import Foundation
import UIKit
import XCTest

@MainActor
final class AgentNativeInteractionTests: XCTestCase {
    /// @spec TEST-1.5: When a scripted native integration run requests mobile gestures or notification taps, the test harness shall drive XCUITest, preserve screenshots with the action sequence ID, require foreground activation-view evidence for notification taps and selected live renderer evidence before completion, and fail the test unless the controller finishes successfully.
    func testScriptedAgentInteractions() async throws {
        try await runScriptedInteractions()
    }

    /// @spec NOTIF-1.26: While the mobile notification view remains active after a reported reconnect failure, a later same-target notification response shall trigger a fresh activation attempt and display its live session without requiring a scene transition or view remount.
    func testNativeNotificationActivation() async throws {
        try await runScriptedInteractions()
    }

    /// @spec TEST-1.13: When a Quick Look integration run drives both provider TUIs, the test harness shall type unique prompts through the native keyboard, open and dismiss the production preview, capture every action, and fail unless all required retained and transient pane cases finish successfully.
    func testNativeQuickLookRetention() async throws {
        try await runScriptedInteractions()
    }

    private func runScriptedInteractions() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["GRAFTTY_AGENT_INTEGRATION_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Run scripts/agent-integration/run.py to supply the isolated controller")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--agent-integration-url", endpoint.absoluteString]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let transport = AgentIntegrationTransport(endpoint: endpoint, client: "gestures")
        try await transport.register(["driver": "XCUITest"])
        var finishedSuccessfully = false
        try await transport.run { command in
            let terminal = app.otherElements["Agent integration terminal"]
            if command.operation == "finish" {
                finishedSuccessfully = command.parameters["result"] == "passed"
                return [:]
            }
            if ["notificationsTap", "notificationsNavigate", "notificationsAuthorize", "notificationsDismissError", "notificationsCapture"].contains(command.operation) {
                return try self.performNotificationGesture(command, app: app)
            }
            if command.operation.hasPrefix("preview") {
                return try self.performPreviewGesture(command, app: app)
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
        XCTAssertTrue(finishedSuccessfully, "The integration controller must finish with a passing result")
    }

    private func performPreviewGesture(_ command: AgentIntegrationCommand, app: XCUIApplication) throws -> [String: String] {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AgentIntegrationError(message) }
        }
        let terminal = app.otherElements["Agent integration terminal"]
        let done = app.buttons["Done"]
        switch command.operation {
        case "previewInput":
            try require(terminal.waitForExistence(timeout: 15), "preview terminal missing")
            let keyboard = app.buttons["Show keyboard"]
            if keyboard.waitForExistence(timeout: 5) { keyboard.tap() }
            else { terminal.tap() }
            try require(app.keyboards.firstMatch.waitForExistence(timeout: 5), "production keyboard did not appear")
            app.typeText(command.parameters["text"] ?? "")
            let submit = app.buttons["Submit return"]
            try require(submit.waitForExistence(timeout: 5), "production terminal submit missing")
            submit.tap()
        case "previewHideKeyboard":
            let hide = app.buttons["Hide keyboard"]
            try require(hide.waitForExistence(timeout: 5), "production hide-keyboard action missing")
            hide.tap()
            try require(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "keyboard did not dismiss")
        case "previewOpen":
            let preview = app.buttons["Preview"]
            try require(preview.waitForExistence(timeout: 15), "production preview toolbar action missing")
            preview.tap()
            try require(done.waitForExistence(timeout: 15), "native Quick Look did not open")
        case "previewDismiss":
            try require(done.waitForExistence(timeout: 5), "native Quick Look Done missing")
            done.tap()
            try require(done.waitForNonExistence(timeout: 10), "Quick Look did not dismiss")
            try require(terminal.waitForExistence(timeout: 5), "source terminal did not return")
        case "previewCapture":
            try require(done.waitForExistence(timeout: 5), "Quick Look disappeared during provider output")
        case "previewBack":
            let back = app.buttons["Back to worktrees"]
            if back.exists { back.tap() }
            else {
                let navigation = app.navigationBars.buttons["Preview worktrees"]
                try require(navigation.waitForExistence(timeout: 5), "embedded pane back navigation missing")
                navigation.tap()
            }
            try require(app.staticTexts["Preview worktrees"].waitForExistence(timeout: 10), "back navigation missed worktree list")
            try require(terminal.waitForNonExistence(timeout: 10), "removed terminal remains mounted")
        default: throw AgentIntegrationError("unsupported preview gesture \(command.operation)")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        let name = "preview-action-\(command.id)-\(command.provider)-\(command.operation)"
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return ["performed": command.operation, "screenshot": name]
    }
}

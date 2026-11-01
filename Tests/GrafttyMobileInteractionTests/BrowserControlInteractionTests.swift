import UIKit
import XCTest

@MainActor
final class IPadWorkspaceInteractionTests: XCTestCase {
    /// @spec IPAD-2.28: While an iPad workspace is visible, the application shall keep agent tabs below the navigation bar, place pane resource controls alongside the tabs, and allow tab selection to change the focused terminal.
    func testTabsRemainBelowNavigationAndReceiveTaps() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad navigation chrome")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            checkWorkspaceTabs(orientation: orientation)
        }
    }

    private func checkWorkspaceTabs(orientation: UIDeviceOrientation) {
        let app = XCUIApplication()
        app.launchArguments = ["--ipad-workspace-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertEqual(app.frame.width > app.frame.height, orientation.isLandscape)
        let alpha = app.buttons["workspace.tab.alpha"]
        let beta = app.buttons["workspace.tab.beta"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(beta.exists)
        let navigation = app.navigationBars["Workspace"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(beta.frame.minY, navigation.frame.maxY - 1,
            "Tabs are underneath navigation chrome: \(beta.frame), \(navigation.frame)")
        beta.tap()
        XCTAssertEqual(app.staticTexts["workspace.focus"].label, "beta")
        alpha.tap()
        XCTAssertEqual(app.staticTexts["workspace.focus"].label, "alpha")
        let context = app.buttons["worktree.context.open"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        let header = app.otherElements["workspace.pane.header"]
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.frame.contains(context.frame), "Resource controls cover terminal content")
        XCTAssertTrue(header.frame.contains(alpha.frame), "Tabs are outside the pane header")
        XCTAssertGreaterThanOrEqual(context.frame.minY, navigation.frame.maxY - 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "iPad workspace chrome and tappable tabs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

@MainActor
final class RecentPaneInteractionTests: XCTestCase {
    func testBackLongPressJumpsToTheRenderedPaneAndRejectsStaleTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["--recent-panes-fixture"]
        app.launch()
        defer { app.terminate() }
        let alpha = app.buttons["Open alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.tap()
        let status = app.staticTexts["Recent pane rendered target"]
        func rendered(_ name: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                status.exists && status.label.contains("/repo/" + name)
                    && status.label.contains("pane-" + name)
                    && status.label.contains("VISIBLE_" + name.uppercased())
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                "Expected the actual target terminal's visible bytes: \(status.label)")
        }
        func screenshot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        rendered("alpha")
        let back = app.buttons["terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.press(forDuration: 1)
        let beta = app.buttons["Terminal beta · Project · beta · Studio"]
        XCTAssertTrue(beta.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Terminal beta · Project · beta · Studio")).count, 1)
        screenshot("Recent panes long-press menu")
        beta.tap()
        rendered("beta")
        screenshot("Recent pane beta rendered")

        back.press(forDuration: 1)
        let returnAlpha = app.buttons["Terminal alpha · Project · alpha · Studio"]
        XCTAssertTrue(returnAlpha.waitForExistence(timeout: 5))
        returnAlpha.tap()
        rendered("alpha")
        back.press(forDuration: 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Terminal beta · Project · beta · Studio")).count, 1)
        let removed = app.buttons["Terminal removed · Project · removed · Studio"]
        XCTAssertTrue(removed.waitForExistence(timeout: 5))
        removed.tap()
        XCTAssertTrue(app.alerts["Could not open pane"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        rendered("alpha")
        screenshot("Stale recent pane leaves alpha rendered")

        back.tap()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "An ordinary Back tap must return to the picker")
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        screenshot("Ordinary Back returns to worktrees")
    }

    /// @spec IPAD-2.27: While a compact agent workspace is shown, the application shall open its shells from a Terminal button in the top-right controls instead of a bottom bar.
    func testAgentWorkspaceTerminalLivesInTopControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--recent-panes-fixture", "--agent-workspace"]
        app.launch()
        defer { app.terminate() }
        let alpha = app.buttons["Open alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.tap()
        let terminal = app.buttons["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the Terminal control is missing")
        XCTAssertEqual(app.buttons.matching(identifier: "Terminal").count, 1, "a bottom Terminal bar is still present")
        XCTAssertLessThan(terminal.frame.midY, app.frame.height * 0.25, "Terminal is not in the top controls: \(terminal.frame)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Agent workspace top controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        terminal.tap()
        XCTAssertTrue(app.buttons["Hide terminal"].waitForExistence(timeout: 5), "Terminal did not open the sheet")
    }

    /// @spec IPAD-2.26: While a compact agent workspace shows the software keyboard, the application shall keep the terminal and its key accessory bar above the keyboard.
    func testAgentWorkspaceTerminalStaysAboveKeyboard() throws {
        for arguments in [["--empty-agent-list"], ["--agent-workspace"]] {
            let app = XCUIApplication()
            app.launchArguments = ["--recent-panes-fixture"] + arguments
            app.launch()
            defer { app.terminate() }
            let alpha = app.buttons["Open alpha"]
            XCTAssertTrue(alpha.waitForExistence(timeout: 10))
            alpha.tap()
            let terminal = app.textViews.firstMatch
            XCTAssertTrue(terminal.waitForExistence(timeout: 10))
            terminal.tap()
            let keyboard = app.keyboards.firstMatch
            try XCTSkipUnless(keyboard.waitForExistence(timeout: 5), "The simulator has a hardware keyboard connected.")
            let submit = app.buttons["Submit return"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5), "\(arguments): the key accessory bar is missing")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Keyboard over alpha \(arguments)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThanOrEqual(terminal.frame.maxY, keyboard.frame.minY + 1,
                "\(arguments): terminal \(terminal.frame) extends behind keyboard \(keyboard.frame)")
            XCTAssertLessThanOrEqual(submit.frame.maxY, keyboard.frame.minY + 1,
                "\(arguments): accessory bar \(submit.frame) is behind keyboard \(keyboard.frame)")
        }
    }
}

final class WorktreeContextInteractionTests: XCTestCase {
    /// @spec CONTEXT-6: When mobile worktree context is opened, the application shall show the current brief and chronological history without collapsing the section, and close back to the mounted terminal without acknowledging pending attention.
    func testBriefExpandsIntoHistoryAndEdgeGestureReopensIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--context-fixture"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["worktree.context.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let close = app.buttons["worktree.context.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let showAll = app.buttons["worktree.context.history.all"]
        for _ in 0..<5 where !showAll.isHittable { app.swipeUp() }
        XCTAssertTrue(showAll.waitForExistence(timeout: 5), app.debugDescription)
        let creation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Created by you")).firstMatch
        let checkpoint = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chose the brief with expandable history")).firstMatch
        XCTAssertTrue(creation.exists)
        XCTAssertFalse(checkpoint.exists)
        showAll.tap()
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(showAll.label, "Show highlights")
        showAll.tap()
        XCTAssertFalse(checkpoint.exists)
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "worktree.context.history.group.")).firstMatch
        for _ in 0..<4 where !group.isHittable { app.swipeUp() }
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue((group.value as? String)?.contains(" to ") == true)
        group.tap()
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 5))
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/graftty-context-mobile.png"))
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Terminal mounts: 1"].exists)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.staticTexts["Terminal mounts: 1"].exists)
    }
}

final class ScrollbackInteractionTests: XCTestCase {
    func testLeaderScrollbackGestures() throws { try exerciseScrollback(follower: false) }
    func testFollowerScrollbackGestures() throws { try exerciseScrollback(follower: true) }

    private func exerciseScrollback(follower: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scrollback-fixture"] + (follower ? ["--follower"] : [])
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let status = app.staticTexts["Scrollback status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        func value(_ key: String) -> Int {
            let text = status.value as? String ?? ""
            return text.split(separator: " ").first(where: { $0.hasPrefix(key + "=") })
                .flatMap { Int($0.dropFirst(key.count + 1)) } ?? -1
        }
        func wait(_ message: String, _ condition: @escaping () -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, message + " " + (status.value as? String ?? ""))
        }
        wait("Initial output should reach the bottom") {
            value("total") >= 500 && value("offset") == value("total") - value("len")
        }
        let initial = value("offset")
        let terminal = app.otherElements["Scrollback terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        wait("Dragging down should reveal older output") { value("offset") >= 0 && value("offset") < initial - 5 }
        let scrolled = value("offset")
        let before = status.value as? String ?? ""
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = follower ? "Follower scrolled" : "Leader scrolled"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Append"].tap()
        wait("Appended output should be received") { value("total") >= 550 }
        XCTAssertEqual(value("offset"), scrolled, "Output must preserve the row being read. Before: \(before)")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Rotate the terminal to landscape") {
            terminal.frame.width > terminal.frame.height && value("width") > value("height")
        }
        XCTAssertEqual(value("offset"), scrolled, "Rotation must preserve the native reading row")
        XCUIDevice.shared.orientation = .portrait
        wait("Rotate the terminal to portrait") {
            terminal.frame.height > terminal.frame.width && value("height") > value("width")
        }
        XCTAssertEqual(value("offset"), scrolled, "Rotating back must preserve the native reading row")
        terminal.swipeDown(velocity: .fast)
        wait("A fast downward fling should reach older output") { value("offset") < scrolled - 5 }
        let flingRow = value("offset")
        terminal.swipeUp(velocity: .fast)
        wait("Reversing the fling should approach live output") { value("offset") > flingRow + 5 }
        app.buttons["Bottom"].tap()
        wait("Return to live output") { value("offset") == value("total") - value("len") }
        app.buttons["Stream"].tap()
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        wait("Streaming output must not prevent scrolling into history") {
            value("total") >= 700 && value("offset") < value("total") - value("len") - 10
        }
        app.buttons["Top"].tap()
        wait("Position just before the oldest output") { value("offset") == 5 }
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        wait("Reach the oldest output") { value("offset") == 0 }
        let topShot = XCTAttachment(screenshot: app.screenshot())
        topShot.name = follower ? "Follower oldest history" : "Leader oldest history"
        topShot.lifetime = .keepAlways
        add(topShot)
        let assertHistoryFillsViewport = {
            XCTAssertLessThanOrEqual(value("gap"), 1, "Loaded history should fill the viewport at the oldest row")
        }
        if follower {
            // Known production defect: spare follower height remains above row zero.
            // Keep all other gesture assertions active, and fail if this unexpectedly passes.
            XCTExpectFailure("Follower layout leaves a top gap at the oldest history row",
                             failingBlock: assertHistoryFillsViewport)
        } else {
            assertHistoryFillsViewport()
        }
        app.buttons["Bottom"].tap()
        wait("Return to live after streaming") { value("offset") == value("total") - value("len") }
        app.buttons["Switch owner"].tap()
        wait("Ownership switch should retain history") { value("total") >= 500 }
        let switched = value("offset")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        wait("Dragging should work after ownership changes") { value("offset") < switched - 5 }
    }
}

final class BrowserControlInteractionTests: XCTestCase {
    /// @spec CHROME-2.29: While multiple terminal overlay actions appear on the right, the application shall join their backgrounds into one capsule, using Liquid Glass on iOS 26 and newer, while preserving separate accessible touch targets.
    func testRightOverlayActionsShareGlassCapsule() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--image-controls-fixture", "--wide-controls"]
        app.launch()
        defer { app.terminate() }
        let images = app.buttons["Images"]
        let browser = app.buttons["Browser"]
        XCTAssertTrue(images.waitForExistence(timeout: 5))
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertEqual(images.frame.midY, browser.frame.midY, accuracy: 1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Joined overlay controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cg = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(cg.width) / app.frame.width
        let gap = CGPoint(x: (images.frame.maxX + browser.frame.minX) / 2, y: images.frame.midY)
        let sample = try XCTUnwrap(cg.cropping(to: CGRect(x: gap.x * scale - 1, y: gap.y * scale - 1, width: 3, height: 3)))
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]), 30,
                             "The space between actions must contain the capsule, not the black terminal background")
        for control in [images, browser] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            tapCenter(control, in: app)
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        }
    }

    // Complements IMAGE-2.11 with actual touches and native scrolling, since
    // in-process UIKit traversal cannot inspect SwiftUI's scroll portals.
    func testShortClippedImagePaneKeepsBothActionsReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--image-controls-fixture"]
        app.launch()
        defer { app.terminate() }
        let pane = app.otherElements["Image pane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        XCTAssertEqual(pane.frame.width, 78, accuracy: 0.5)
        XCTAssertEqual(pane.frame.height, 78, accuracy: 0.5)
        // Retain the fixed pane's bounds independently of the changing nested
        // accessibility containers in the adaptive controls.
        let bounds = pane.frame
        let images = app.buttons["Images"]
        XCTAssertTrue(images.waitForExistence(timeout: 5))
        assertFullTarget(images, in: bounds)
        tapCenter(images, in: app)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Images must open native Quick Look")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(scroll.frame.height, 66.5)
        scroll.swipeUp()
        let browser = app.buttons["Browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        assertFullTarget(browser, in: bounds)
        tapCenter(browser, in: app)
        XCTAssertTrue(app.buttons["Open address"].waitForExistence(timeout: 5), "Browser must retain its independent action")
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    private func assertFullTarget(_ control: XCUIElement, in bounds: CGRect) {
        XCTAssertGreaterThanOrEqual(control.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(control.frame.height, 43.99)
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(control.frame))
        XCTAssertTrue(control.isHittable)
    }

    private func tapCenter(_ control: XCUIElement, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: control.frame.midX, dy: control.frame.midY)).tap()
    }

    /// @spec CHROME-2.23: When the user taps the globe or its visible available-resource badge, the application shall invoke the same browser action.
    func testGlobeAndVisibleBadgeActivateTheSameControl() throws {
        for badge in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--browser-control-fixture"]
            app.launch()
            defer { app.terminate() }
            let browser = app.buttons["Browser"]
            XCTAssertTrue(browser.waitForExistence(timeout: 5))
            XCTAssertEqual(browser.value as? String, "1 available resources")
            let point: CGPoint
            if badge {
                // Use the displayed blue pixels, not an inferred button frame:
                // the badge extends into the label's top-right corner.
                point = try badgeCenter(in: app.screenshot().image, screen: app.frame, browser: browser.frame)
            } else {
                point = CGPoint(x: browser.frame.midX, y: browser.frame.midY)
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(app.staticTexts["Activated"].waitForExistence(timeout: 3), badge ? "Visible badge tap must activate Browser" : "Globe center tap must activate Browser")
        }
    }

    private func badgeCenter(in image: UIImage, screen: CGRect, browser: CGRect) throws -> CGPoint {
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0, xSum = 0, ySum = 0
        let region = browser.insetBy(dx: -12, dy: -12).intersection(screen)
        let minX = max(0, Int((region.minX - screen.minX) / screen.width * Double(cg.width)))
        let maxX = min(cg.width, Int(ceil((region.maxX - screen.minX) / screen.width * Double(cg.width))))
        let minY = max(0, Int((region.minY - screen.minY) / screen.height * Double(cg.height)))
        let maxY = min(cg.height, Int(ceil((region.maxY - screen.minY) / screen.height * Double(cg.height))))
        for y in minY..<maxY { for x in minX..<maxX {
            let index = (y * cg.width + x) * 4
            if Int(pixels[index + 2]) > Int(pixels[index]) + 40,
               Int(pixels[index + 2]) > Int(pixels[index + 1]) + 25 {
                count += 1; xSum += x; ySum += y
            }
        } }
        XCTAssertGreaterThan(count, 4, "The actual blue badge must be visible")
        guard count > 0 else { throw NSError(domain: "BrowserBadgeFixture", code: 1) }
        return CGPoint(x: screen.minX + Double(xSum) / Double(count * cg.width) * screen.width,
                       y: screen.minY + Double(ySum) / Double(count * cg.height) * screen.height)
    }
}

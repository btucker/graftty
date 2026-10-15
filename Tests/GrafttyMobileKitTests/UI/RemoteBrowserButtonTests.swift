#if canImport(UIKit)
import GrafttyProtocol
import Observation
import QuickLook
import SafariServices
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite(.serialized)
@MainActor
struct RemoteBrowserButtonTests {
    @Test("Dismissed automatic previews stay consumed when the pane view is recreated", .timeLimit(.minutes(1)))
    func dismissedPreviewStaysClosedAfterViewRecreation() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, autoPreview: true)
        defer { close(fixture) }
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        try await finishPresentation(in: fixture)
        let reads = fixture.state.reads
        fixture.state.visible = false
        try await Task.sleep(for: .milliseconds(300))
        fixture.state.visible = true
        try await waitForImages(fixture)
        try await Task.sleep(for: .seconds(3.2))
        #expect(fixture.host.presentedViewController == nil)
        #expect(fixture.state.reads == reads)
    }

    @Test("Automatic preview downloads cancelled before presentation retry when focus returns", .timeLimit(.minutes(1)))
    func cancelledAutomaticPreviewRetriesWhenFocusReturns() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, imageInitiallyAvailable: false, autoPreview: true)
        defer { close(fixture) }
        fixture.state.slowRead = true
        fixture.state.offers = [imageOffer()]
        try await waitUntil { fixture.state.reads > 0 }
        fixture.state.focused = false
        try await waitUntil { fixture.state.cancelledReads == 1 }
        fixture.state.slowRead = false
        fixture.state.focused = true
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
    }

    @Test("Failed automatic previews do not retry when the pane view is recreated", .timeLimit(.minutes(1)))
    func failedAutomaticPreviewDoesNotRepeatAfterViewRecreation() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, imageInitiallyAvailable: false, autoPreview: true)
        defer { close(fixture) }
        fixture.state.failRead = true
        fixture.state.offers = [imageOffer()]
        try await waitUntil { fixture.host.presentedViewController is UIAlertController }
        let reads = fixture.state.reads
        fixture.state.visible = false
        try await Task.sleep(for: .milliseconds(300))
        fixture.state.visible = true
        try await waitForImages(fixture)
        try await Task.sleep(for: .seconds(3.2))
        #expect(fixture.state.reads == reads)
    }

    @Test("@spec PREVIEW-2.8: When a multi-file preview arrives for the focused owning mobile pane, the application shall automatically download and present the complete collection in order and remove every local snapshot after dismissal.", .timeLimit(.minutes(1)))
    func collectionAutoOpensAndCleansUpEveryFile() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, imageInitiallyAvailable: false, autoPreview: true)
        defer { close(fixture) }
        let group = UUID()
        fixture.state.offers = ["before.png", "after.png"].map {
            RemoteOpenOffer(id: UUID(), filename: $0, byteCount: imageBytes.count, paneSessionName: "pane",
                            previewKind: "file", previewOwnerDeviceID: .init(value: "fixture-phone"), previewGroupID: group)
        }
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        let controller = try #require(quickLook(in: fixture.host.presentedViewController))
        let source = try #require(controller.dataSource)
        #expect(source.numberOfPreviewItems(in: controller) == 2)
        let files = try (0..<2).map { try #require(source.previewController(controller, previewItemAt: $0).previewItemURL) }
        #expect(files.map(\.lastPathComponent) == ["before.png", "after.png"])
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try await finishPresentation(in: fixture)
        try await waitUntil { files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
    }

    @Test("@spec IMAGE-2.11: When the mobile pane lacks horizontal room for Preview and Browser, the application shall stack their existing minimum 44-point targets vertically, scroll the column if pane height is insufficient, and keep each action reachable within the clipped pane while retaining horizontal controls in wider panes.", .timeLimit(.minutes(1)), arguments: [CGFloat(78), CGFloat(320)])
    func imageControlsFitClippedPane(paneWidth: CGFloat) async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, paneWidth: paneWidth)
        defer { close(fixture) }
        try await waitForImages(fixture)
        let bounds = fixture.host.view.convert(fixture.host.view.bounds, to: fixture.window.screen.coordinateSpace)
        #expect(abs(bounds.width - paneWidth) < 1)
        let objects = accessibilityObjects(in: fixture.host.view)
        let images = try #require(objects.first { $0.accessibilityLabel == "Preview" })
        let browser = try #require(objects.first { $0.accessibilityLabel == "Browser" })
        for control in [images, browser] {
            let frame = control.accessibilityFrame
            // Screen-coordinate conversion can round a 44-point frame just below 44.
            #expect(frame.width >= 43.99 && frame.height >= 43.99)
            #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Both full hit targets must remain inside the clipped pane")
            let point = fixture.window.convert(control.accessibilityActivationPoint, from: fixture.window.screen.coordinateSpace)
            let hit = try #require(fixture.window.hitTest(point, with: nil))
            #expect(hit.isDescendant(of: fixture.host.view), "The activation point must hit the pane's actual hosting view")
        }
        if paneWidth == 78 {
            #expect(abs(images.accessibilityFrame.midX - browser.accessibilityFrame.midX) < 1)
            #expect(browser.accessibilityFrame.minY >= images.accessibilityFrame.maxY)
        } else {
            #expect(abs(images.accessibilityFrame.midY - browser.accessibilityFrame.midY) < 1)
            #expect(browser.accessibilityFrame.minX >= images.accessibilityFrame.maxX)
        }
        try #require(images.accessibilityActivate())
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        try await finishPresentation(in: fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { accessibilityObjects(in: sheet.view).contains { $0.accessibilityLabel == "Done" } }
        try await finishPresentation(in: fixture)
    }

    @Test("@spec CHROME-2.27: When a mounted mobile browser backgrounds and its ownership snapshot clears during transport suspension, the application shall retain the browser sheet until explicit dismissal or confirmed ownership loss.")
    func mountedBrowserSurvivesClearedOwnershipDuringBackground() async throws {
        let fixture = try makeButtonFixture(owner: true)
        defer { close(fixture) }
        try await waitUntil { accessibilityObjects(in: fixture.host.view).contains { $0.accessibilityLabel == "Browser" } }
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { !sheet.isBeingPresented && sheet.view.window != nil }
        fixture.state.active = false
        fixture.state.ready = false
        fixture.state.hasSnapshot = false
        fixture.state.owner = false
        try await Task.sleep(for: .milliseconds(500))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        fixture.state.active = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        fixture.state.owner = true
        fixture.state.hasSnapshot = true
        fixture.state.ready = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        fixture.state.owner = false
        try await waitUntil { fixture.host.presentedViewController == nil }
    }

    @Test("@spec CHROME-2.28: While a retained mobile browser sheet's biometric gate is locked, the application shall hide its page, address, tab metadata, and browser controls until the gate unlocks.")
    func retainedBrowserHidesControlsWhenBiometricGateLocks() async throws {
        let gate = BiometricGate(authenticator: BrowserUnlockAuthenticator(), idleTimeout: 0)
        gate.applicationWillEnterForeground()
        await gate.authenticate()
        try #require(gate.state == .unlocked)
        let fixture = try makeButtonFixture(owner: true)
        defer { close(fixture) }
        fixture.state.gate = gate
        try await waitUntil { accessibilityObjects(in: fixture.host.view).contains { $0.accessibilityLabel == "Browser" } }
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { accessibilityObjects(in: sheet.view).contains { $0.accessibilityLabel == "Open address" } }
        gate.applicationDidEnterBackground()
        gate.applicationWillEnterForeground()
        try #require(gate.state == .locked)
        try await Task.sleep(for: .milliseconds(200))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        #expect(!accessibilityObjects(in: sheet.view).contains { $0.accessibilityLabel == "Open address" || $0.accessibilityLabel == "Tabs" })
        await gate.authenticate()
        try await waitUntil { accessibilityObjects(in: sheet.view).contains { $0.accessibilityLabel == "Open address" } }
    }

    private struct BrowserUnlockAuthenticator: BiometricAuthenticator {
        func authenticate() async -> Result<Void, Error> { .success(()) }
    }

    @Test("@spec IMAGE-2.4: When a mobile preview request arrives for the focused owning pane, the application shall automatically present native Quick Look once and retain a Preview action for manual reopening after dismissal.", .timeLimit(.minutes(1)))
    func previewsAutoOpenOnceAndCanBeReopened() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true, imageInitiallyAvailable: false, autoPreview: true)
        defer { close(fixture) }
        let incoming = imageOffer()
        let field = UITextField(frame: CGRect(x: 20, y: 40, width: 100, height: 40))
        fixture.parent.view.addSubview(field)
        field.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(150))
        #expect(field.isFirstResponder)
        #expect(!accessibilityObjects(in: fixture.host.view).contains { $0.accessibilityLabel == "Preview" })
        fixture.state.offers = [incoming]
        try await waitForImages(fixture, filename: "image.png")
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        #expect(!field.isFirstResponder)
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { quickLook(in: sheet) != nil }
        let controller = try #require(quickLook(in: sheet))
        let source = try #require(controller.dataSource)
        let url = try #require(source.previewController(controller, previewItemAt: 0).previewItemURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await finishPresentation(in: fixture)
        try await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        try await Task.sleep(for: .seconds(3.2))
        #expect(fixture.host.presentedViewController == nil)
        try await waitForImages(fixture)
        try activateImages(in: fixture.host.view)
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        fixture.state.owner = false
        try await waitUntil { fixture.host.presentedViewController == nil }
    }

    @Test("@spec IMAGE-2.10: While a mobile image preview is mounted, the application shall retain its local file and presentation across temporary scene pauses and system sharing, until actual pane, ownership or offer changes or dismissal.", .timeLimit(.minutes(1)))
    func mountedImageSurvivesScenePause() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true)
        defer { close(fixture) }
        try await waitForImages(fixture)
        try activateImages(in: fixture.host.view)
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { !sheet.isBeingPresented && sheet.view.window != nil }
        let controller = try #require(quickLook(in: sheet))
        let url = try #require(controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL)
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.modalPresentationStyle = .fullScreen
        share.popoverPresentationController?.sourceView = sheet.view
        sheet.present(share, animated: false)
        try await waitUntil { share.view.window != nil }
        fixture.state.active = false
        try await Task.sleep(for: .milliseconds(500))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(Bool(sheet.presentedViewController === share))
        share.dismiss(animated: false)
        try await waitUntil { sheet.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(Bool(fixture.host.presentedViewController === sheet), "Uncovering an already mounted image must not require an active scene")
        fixture.state.active = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        try await finishPresentation(in: fixture)
        try await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
    }

    @Test("@spec IMAGE-2.5: If the latest mobile image changes during download or viewing, then the application shall discard stale bytes, close the old preview and automatically open the replacement when the pane remains focused and owned.", .timeLimit(.minutes(1)))
    func replacementCancelsStaleDownloadAndMountedPreview() async throws {
        let fixture = try makeButtonFixture(owner: true, image: true)
        defer { close(fixture) }
        fixture.state.slowRead = true
        try await waitForImages(fixture)
        try activateImages(in: fixture.host.view)
        try await waitUntil { fixture.state.reads > 0 }
        fixture.state.offers = [imageOffer("replacement.png")]
        try await Task.sleep(for: .seconds(3.3))
        fixture.state.slowRead = false
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
        let controller = try #require(quickLook(in: fixture.host.presentedViewController))
        let url = try #require(controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL)
        #expect(url.lastPathComponent == "replacement.png")
        fixture.state.offers = [imageOffer("newest.png")]
        try await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        try await waitUntil {
            guard let next = quickLook(in: fixture.host.presentedViewController) else { return false }
            return next.dataSource?.previewController(next, previewItemAt: 0).previewItemURL?.lastPathComponent == "newest.png"
        }

    }

    @Test("@spec IMAGE-2.6: If a mobile image is unavailable or cannot be downloaded or natively previewed, then the application shall show an actionable image error and allow a later retry.", .timeLimit(.minutes(1)), arguments: [false, true])
    func imageDownloadFailureExplainsRetry(unsupportedPreview: Bool) async throws {
        let fixture = try makeButtonFixture(owner: true, image: true)
        defer { close(fixture) }
        fixture.state.failRead = !unsupportedPreview
        fixture.state.unsupportedPreview = unsupportedPreview
        if unsupportedPreview { fixture.state.offers = [imageOffer("image.graftty-unknown-preview")] }
        try await waitForImages(fixture, filename: unsupportedPreview ? "image.graftty-unknown-preview" : "image.png")
        try activateImages(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController is UIAlertController }
        let alert = try #require(fixture.host.presentedViewController as? UIAlertController)
        #expect(alert.message?.contains("graftty preview") == true)
        #expect(alert.message?.contains(unsupportedPreview ? "Quick Look supported file" : "download") == true)
        try await finishPresentation(in: fixture)
        fixture.state.failRead = false
        fixture.state.unsupportedPreview = false
        if unsupportedPreview { fixture.state.offers = [imageOffer()] }
        try await waitForImages(fixture, filename: "image.png")
        try activateImages(in: fixture.host.view)
        try await waitUntil { quickLook(in: fixture.host.presentedViewController) != nil }
    }

    @Test("Image downloads cancel when the originating pane loses focus or its worktree changes", .timeLimit(.minutes(1)), arguments: [false, true])
    func imageDownloadCancelsAfterScopeChange(worktreeChanges: Bool) async throws {
        let fixture = try makeButtonFixture(owner: true, image: true)
        defer { close(fixture) }
        fixture.state.slowRead = true
        try await waitForImages(fixture)
        try activateImages(in: fixture.host.view)
        try await waitUntil { fixture.state.reads > 0 }
        if worktreeChanges { fixture.state.worktree = "/other" }
        else { fixture.state.focused = false }
        try await waitUntil { fixture.state.cancelledReads == 1 }
        #expect(fixture.host.presentedViewController == nil)
    }

    private func imageOffer(_ name: String = "image.png") -> RemoteOpenOffer {
        .init(id: UUID(), filename: name, byteCount: imageBytes.count, paneSessionName: "pane",
              previewKind: "image", previewOwnerDeviceID: .init(value: "fixture-phone"))
    }
    private var imageBytes: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }
    private func quickLook(in controller: UIViewController?) -> QLPreviewController? {
        guard let controller else { return nil }
        if let preview = controller as? QLPreviewController { return preview }
        for child in controller.children { if let preview = quickLook(in: child) { return preview } }
        return nil
    }
    private func waitForImages(_ fixture: ButtonFixture, filename: String? = nil) async throws {
        try await waitUntil {
            fixture.host.view.layoutIfNeeded()
            return accessibilityObjects(in: fixture.host.view).contains {
                $0.accessibilityLabel == "Preview" && (filename == nil || $0.accessibilityValue == filename)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    private func activateImages(in view: UIView) throws {
        let button = try #require(accessibilityObjects(in: view).first { $0.accessibilityLabel == "Preview" })
        try #require(button.accessibilityActivate())
    }

    @Test("A mounted browser survives scene pauses and remains retryable after its actual host is removed", .timeLimit(.minutes(1)))
    func mountedFreshHostRetainsSheetDuringScenePause() async throws {
        let fixture = try makeButtonFixture(owner: true, authentication: false)
        defer { close(fixture) }
        try await waitForBadge(fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { !sheet.isBeingPresented && sheet.view.window != nil }
        fixture.state.active = false
        try await Task.sleep(for: .milliseconds(500))
        fixture.state.active = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(Bool(fixture.host.presentedViewController === sheet))
        // Remove the browser source through SwiftUI, as pane navigation does.
        fixture.state.visible = false
        try await waitUntil { fixture.host.presentedViewController == nil }
        fixture.state.visible = true
        try await waitForBadge(fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let retry = try #require(fixture.host.presentedViewController)
        try await waitUntil { !retry.isBeingPresented && retry.view.window != nil }
        try await waitUntil { accessibilityObjects(in: retry.view).contains { $0.accessibilityLabel == "Done" } }
        let safari = SFSafariViewController(url: URL(string: "http://127.0.0.1:1/")!)
        safari.modalPresentationStyle = .fullScreen
        retry.present(safari, animated: false)
        try await waitUntil { safari.view.window != nil && safari.presentingViewController != nil }
        #expect(Bool(fixture.host.presentedViewController === retry), "A system Safari modal must not abandon its underlying browser")
        safari.dismiss(animated: false)
        try await waitUntil { retry.presentedViewController == nil }
        try await finishPresentation(in: fixture)
    }
    @Test("@spec CHROME-2.18: While the terminal browser control is visible, the application shall use the same primary glyph, plain button and translucent circle styling as Back while preserving its available-resource badge, busy indication and accessibility.", arguments: [0, 3])
    func browserUsesSharedFloatingStyle(availableCount: Int) async throws {
        let image = try await render(RemoteOpenButton.floatingControl(
            availableCount: availableCount, isBusy: false, action: {}), name: "browser-\(availableCount)")
        let pixels = try glyphPixels(image)
        if availableCount == 0 {
            let back = try await render(TerminalFloatingGlyphButton(
                systemName: "chevron.left", accessibilityLabel: "Back", action: {}), name: "back")
            let reference = try glyphPixels(back)
            #expect(pixels.blue == reference.blue)
            #expect(reference.visible >= 4)
        }
        #expect(pixels.blue == 0, "Browser glyph must use Back's primary foreground, not accent blue")
        #expect(pixels.visible >= 4, "The rendered globe must be visible")
        #expect(availableCount == 0 ? pixels.totalBlue == 0 : pixels.totalBlue >= 4,
                "Only a nonempty resource badge uses the accent tint")
    }

    @Test("The busy browser control keeps its shared foreground and resource badge")
    func busyControlKeepsSharedForeground() async throws {
        let image = try await render(RemoteOpenButton.floatingControl(
            availableCount: 3, isBusy: true, action: {}), name: "browser-busy")
        let pixels = try glyphPixels(image)
        #expect(pixels.blue == 0)
        #expect(pixels.visible >= 4, "The busy indicator must be visible")
        #expect(pixels.totalBlue >= 4, "The resource badge remains visible while busy")
    }

    @Test("@spec CHROME-2.22: When the badged browser control has an abandoned presentation reservation, the application shall allow an authorized retry to present the originating browser after foreground or follower-to-owner transitions.", .timeLimit(.minutes(1)), arguments: [false, true])
    func interruptedBadgedButtonRemainsRetryable(followerFirst: Bool) async throws {
        let fixture = try makeButtonFixture(owner: !followerFirst, pending: true)
        defer { close(fixture) }
        try await waitForBadge(fixture)
        if followerFirst {
            fixture.state.owner = true
            try await waitForBadge(fixture)
        }
        try activateBrowser(in: fixture.host.view)
        // Remove the retained hosting controller synchronously, before the
        // SwiftUI update can mount the requested sheet and owe onDismiss.
        fixture.host.willMove(toParent: nil)
        fixture.host.view.removeFromSuperview()
        fixture.host.removeFromParent()
        fixture.state.active = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.host.presentedViewController == nil)
        fixture.state.active = true
        attach(fixture)
        try await waitForBadge(fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let sheet = try #require(fixture.host.presentedViewController)
        try await waitUntil { !sheet.isBeingPresented && sheet.view.window != nil }
        #expect(!(sheet is UIAlertController), "Retry must present the browser rather than silently return")
        #expect(accessibilityObjects(in: sheet.view).contains { $0.accessibilityLabel == "Done" })
        fixture.state.owner = false
        try await waitUntil { fixture.host.presentedViewController == nil }
        // UIKit removes the controller before SwiftUI delivers its dismissal
        // callback and installs the newly authorized button action.
        try await Task.sleep(for: .milliseconds(100))
        fixture.state.owner = true
        try await waitForBadge(fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let retry = try #require(fixture.host.presentedViewController)
        try await waitUntil { !retry.isBeingPresented && retry.view.window != nil }
        try await waitUntil { accessibilityObjects(in: retry.view).contains { $0.accessibilityLabel == "Done" } }
        try await finishPresentation(in: fixture)
    }

    @Test("@spec CHROME-2.21: If a manual browser action is rejected for unavailable presentation or stale pane authorization, then the application shall display actionable feedback instead of silently ignoring the tap.", .timeLimit(.minutes(1)), arguments: [true, false])
    func unavailableBadgedButtonExplainsRejection(unowned: Bool) async throws {
        let fixture = try makeButtonFixture(owner: !unowned)
        fixture.state.ready = unowned
        defer { close(fixture) }
        try await waitForBadge(fixture)
        try activateBrowser(in: fixture.host.view)
        try await waitUntil { fixture.host.presentedViewController != nil }
        let alert = try #require(fixture.host.presentedViewController as? UIAlertController)
        #expect(alert.title == "Could not open resource")
        #expect(alert.message?.contains(unowned ? "control" : "Reconnect") == true)
        try await finishPresentation(in: fixture)
    }

    @MainActor @Observable
    final class ButtonState {
        var owner: Bool
        var active = true
        var ready = true
        var hasSnapshot = true
        var gate: BiometricGate?
        var visible = true
        var offers: [RemoteOpenOffer] = []
        var slowRead = false
        var failRead = false
        var unsupportedPreview = false
        var reads = 0
        var cancelledReads = 0
        var worktree = "/fixture"
        var focused = true
        init(owner: Bool) { self.owner = owner }
    }
    private struct ButtonFixture {
        let window: UIWindow
        let parent: UIViewController
        let host: UIHostingController<AnyView>
        let state: ButtonState
        let previous: UIWindow?
        let directory: URL
    }

    private func makeButtonFixture(owner: Bool, pending: Bool = false, authentication: Bool = true,
                                   image: Bool = false, imageInitiallyAvailable: Bool = true, paneWidth: CGFloat? = nil, autoPreview: Bool = false) throws -> ButtonFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = RemoteConnectionCoordinator(directory: directory, connectionsAllowedInitially: false)
        let host = Host(label: "Fixture Mac", baseURL: URL(string: "https://host.invalid")!)
        let device = RemoteDeviceID(value: "fixture-phone")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0,
            url: URL(string: authentication
                     ? "https://provider.invalid/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A43210%2Fcallback&state=unchanged"
                     : "https://provider.invalid/page"),
            paneSessionName: "pane", browserOwnerDeviceID: device)
        // Keep a real badge while suppressing automatic presentation. The
        // fixture exercises the user's explicit SwiftUI button action.
        coordinator.dismissAuthenticationOffer(offer.id)
        var presentation = ChromeOfferPresentation()
        // Explicitly begin a request without providing a sheet. This models
        // the abandoned reservation separately from SwiftUI's mount timing.
        if pending { _ = presentation.begin(offer.id) }
        let state = ButtonState(owner: owner)
        state.offers = image && !imageInitiallyAvailable ? [] : [image ? imageOffer() : offer]
        // Most fixtures exercise reopening a preview the user has already dismissed.
        if !autoPreview, image {
            for offer in state.offers { coordinator.completePreviewAutoOpen(offer.id) }
        }
        let button = ButtonFixtureView(state: state, coordinator: coordinator, host: host, imageBytes: imageBytes,
                                      device: device, initialPresentation: presentation, paneWidth: paneWidth)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let parent = UIViewController()
        parent.view.backgroundColor = .black
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let fixture = ButtonFixture(window: window, parent: parent, host: UIHostingController(rootView: AnyView(button)),
                                    state: state, previous: previous, directory: directory)
        attach(fixture)
        if let paneWidth {
            fixture.host.view.frame = CGRect(x: 20, y: 100, width: paneWidth, height: 200)
            fixture.host.view.layoutIfNeeded()
        }
        return fixture
    }

    private struct ButtonFixtureView: View {
        let state: ButtonState
        let coordinator: RemoteConnectionCoordinator
        let host: Host
        let imageBytes: Data
        let device: RemoteDeviceID
        let initialPresentation: ChromeOfferPresentation
        let paneWidth: CGFloat?
        var body: some View {
            if state.visible {
                let button = RemoteOpenButton(host: host, worktree: state.worktree, coordinator: coordinator, sessionName: "pane",
                    ownerDeviceID: state.owner ? device : nil, isActive: state.active,
                    managementTransport: { request, requestedHost in
                        #expect(requestedHost.id == host.id)
                        if case .openResource(_, .read) = request {
                            state.reads += 1
                            if state.slowRead {
                                do { try await Task.sleep(for: .seconds(4)) }
                                catch { state.cancelledReads += 1; throw error }
                            }
                            if state.failRead { return .error(code: "unavailable", message: "Unavailable", forceAllowed: false, shortStatus: nil) }
                            return .openResource(.chunk(state.unsupportedPreview ? Data(repeating: 0, count: imageBytes.count) : imageBytes))
                        }
                        return .openResource(.offers(state.offers))
                    }, browserConnectionReady: state.ready, isPaneFocused: state.focused, hasOwnershipSnapshot: state.hasSnapshot,
                    isPaneOwner: { state.owner }, canPresentAuthentication: { true }, terminalRequest: .constant(nil), chromePresentation: initialPresentation)
                    .environment(\.scenePhase, state.active ? .active : .background)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.biometricGate, state.gate)
                if let paneWidth {
                    Color.black.frame(width: paneWidth, height: 200)
                        .overlay(alignment: .topTrailing) {
                            button.modifier(TerminalFloatingControlPlacement()).padding(.trailing, 12)
                        }
                        .clipped()
                        .accessibilityElement(children: .contain)
                } else { button }
            }
        }
    }

    private func attach(_ fixture: ButtonFixture) {
        fixture.parent.addChild(fixture.host)
        fixture.parent.view.addSubview(fixture.host.view)
        fixture.host.view.frame = fixture.parent.view.bounds
        fixture.host.didMove(toParent: fixture.parent)
        fixture.host.view.layoutIfNeeded()
    }
    private func close(_ fixture: ButtonFixture) {
        fixture.host.dismiss(animated: false)
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previous?.makeKey()
        try? FileManager.default.removeItem(at: fixture.directory)
    }
    private func finishPresentation(in fixture: ButtonFixture) async throws {
        if let presented = fixture.host.presentedViewController {
            if presented is UIAlertController {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    presented.dismiss(animated: false) { continuation.resume() }
                }
            } else {
                if let image = quickLook(in: presented) {
                    try await waitUntil { image.view.window != nil && !presented.isBeingPresented }
                    let navigation = try #require(image.navigationController)
                    #expect(!navigation.isNavigationBarHidden)
                    let done = try #require(image.navigationItem.leftBarButtonItem)
                    #expect(done.title == "Done")
                    #expect(done.accessibilityLabel == "Done")
                    let action = try #require(done.action)
                    try #require(UIApplication.shared.sendAction(action, to: done.target, from: done, for: nil),
                                 "Dismiss through the mounted native bar button's target/action")
                } else {
                    try await waitUntil { accessibilityObjects(in: presented.view).contains { $0.accessibilityLabel == "Done" } }
                    let button = try #require(accessibilityObjects(in: presented.view).first { $0.accessibilityLabel == "Done" })
                    try #require(button.accessibilityActivate(), "Dismiss using the actual resource Done action")
                }
            }
        }
        try await waitUntil { fixture.host.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(50))
    }
    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Hosted browser condition did not become true", sourceLocation: sourceLocation)
    }
    private func waitForBadge(_ fixture: ButtonFixture) async throws {
        do {
            try await waitUntil {
                fixture.host.view.layoutIfNeeded()
                return accessibilityObjects(in: fixture.host.view).contains {
                    $0.accessibilityLabel == "Browser" && $0.accessibilityValue == "1 available resources"
                }
            }
            // Let SwiftUI publish the action closure after an ownership change.
            try await Task.sleep(for: .milliseconds(30))
        } catch {
            print("Browser fixture accessibility:", accessibilityObjects(in: fixture.host.view).map {
                "\(type(of: $0)) label=\($0.accessibilityLabel ?? "nil") value=\($0.accessibilityValue ?? "nil")"
            })
            throw error
        }
    }
    private func activateBrowser(in view: UIView) throws {
        let button = try #require(accessibilityObjects(in: view).first { $0.accessibilityLabel == "Browser" })
        try #require(button.accessibilityActivate(), "Activate the actual SwiftUI browser button")
    }
    private func accessibilityObjects(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), result.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
            let count = max(0, min(object.accessibilityElementCount(), 128))
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
        return result
    }

    private func render(_ button: some View, name: String) async throws -> UIImage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let parent = UIViewController()
        parent.view.backgroundColor = .black
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: button.padding(14).frame(width: 72, height: 72)
            .environment(\.colorScheme, .dark).tint(.blue))
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.view.frame = CGRect(x: 20, y: 100, width: 72, height: 72)
        host.didMove(toParent: parent)
        host.view.backgroundColor = .black
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            #expect(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-browser-control-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        return image
    }

    private func glyphPixels(_ image: UIImage) throws -> (blue: Int, visible: Int, totalBlue: Int) {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        var blue = 0, visible = 0, totalBlue = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if Int(bytes[index + 2]) > Int(bytes[index]) + 40,
               Int(bytes[index + 2]) > Int(bytes[index + 1]) + 25 { totalBlue += 1 }
        }
        // Ignore the deliberately tinted resource badge outside the glyph.
        for y in 26..<47 { for x in 26..<43 {
            let index = (y * cgImage.width + x) * 4
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), value = Int(bytes[index + 2])
            if value > red + 40, value > green + 25 { blue += 1 }
            if max(red, green, value) > 130 { visible += 1 }
        } }
        return (blue, visible, totalBlue)
    }
}
#endif

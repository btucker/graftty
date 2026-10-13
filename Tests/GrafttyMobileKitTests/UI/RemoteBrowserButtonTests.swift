#if canImport(UIKit)
import GrafttyProtocol
import Observation
import SafariServices
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite(.serialized)
@MainActor
struct RemoteBrowserButtonTests {
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
        try await waitUntil { accessibilityObjects(in: retry.view).contains { $0 is UISegmentedControl } }
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
        #expect(accessibilityObjects(in: sheet.view).contains { $0 is UISegmentedControl })
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
        try await waitUntil { accessibilityObjects(in: retry.view).contains { $0 is UISegmentedControl } }
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
        var visible = true
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

    private func makeButtonFixture(owner: Bool, pending: Bool = false, authentication: Bool = true) throws -> ButtonFixture {
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
        let button = ButtonFixtureView(state: state, coordinator: coordinator, host: host, offer: offer, device: device, initialPresentation: presentation)
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
        return fixture
    }

    private struct ButtonFixtureView: View {
        let state: ButtonState
        let coordinator: RemoteConnectionCoordinator
        let host: Host
        let offer: RemoteOpenOffer
        let device: RemoteDeviceID
        let initialPresentation: ChromeOfferPresentation
        var body: some View {
            if state.visible {
                RemoteOpenButton(host: host, worktree: "/fixture", coordinator: coordinator, sessionName: "pane",
                    ownerDeviceID: state.owner ? device : nil, isActive: state.active,
                    managementTransport: { _, requestedHost in
                        #expect(requestedHost.id == host.id)
                        return .openResource(.offers([offer]))
                    }, browserConnectionReady: state.ready, isPaneFocused: true, hasOwnershipSnapshot: true,
                    isPaneOwner: { state.owner }, canPresentAuthentication: { true }, terminalRequest: .constant(nil), chromePresentation: initialPresentation)
                    .environment(\.scenePhase, state.active ? .active : .background)
                    .environment(\.accessibilityEnabled, true)
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
                let button = try #require(accessibilityObjects(in: presented.view).first { $0.accessibilityLabel == "Done" })
                try #require(button.accessibilityActivate(), "Dismiss using the actual resource Done action")
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

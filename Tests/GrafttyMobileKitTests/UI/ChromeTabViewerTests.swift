import Testing
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyMobileKit
#if canImport(UIKit)
import SwiftUI
import UIKit
import Observation
#endif

struct ChromeTabViewerTests {
    @Test("@spec CHROME-2.1: When a phone taps a fitted Chrome frame, the application shall map only image pixels to normalized browser coordinates and reject letterbox taps.")
    func mapsFittedImage() {
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 200, y: 400), in: CGSize(width: 400, height: 800)) == CGPoint(x: 0.5, y: 0.5))
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 200, y: 200), in: CGSize(width: 400, height: 800)) == nil)
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 0, y: 250), in: CGSize(width: 400, height: 800)) == CGPoint(x: 0, y: 0))
        #expect(ChromeTabCoordinates.normalized(.zero, in: .zero) == nil)
    }

    @MainActor
    @Test("@spec CHROME-2.26: When the mobile remote browser reconnects after suspension, the application shall restore its selected tab if it still exists and shall not repeat a successfully acknowledged initial URL launch.", arguments: [false, true])
    func reconnectRestoresSelectionWithoutRelaunch(initialURL: Bool) async throws {
        let model = ChromeTabViewerModel()
        let driver = ResumeSelectionDriver()
        let launch = initialURL ? ChromeTabInitialLaunch(id: UUID(), url: "https://example.com/first") : nil
        let first = Task { await model.run(target: "pane", initialLaunch: launch, onLaunch: {}, makeDriver: { driver }) }
        defer { first.cancel(); model.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        while model.state.selectedTabID == nil || model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.state.selectedTabID != nil && !model.busy)
        #expect(await model.send(.select(tabID: "second"), target: "pane"))
        first.cancel()
        await first.value
        model.suspend()
        #expect(!model.isConnected && model.state.selectedTabID == "second")
        struct ReconnectFailure: Error {}
        await model.run(target: "pane", initialLaunch: launch, onLaunch: {}, makeDriver: { throw ReconnectFailure() })
        let second = Task { await model.run(target: "pane", initialLaunch: launch, onLaunch: {}, makeDriver: { driver }) }
        defer { second.cancel(); model.close() }
        let resumedDeadline = ContinuousClock.now + .seconds(3)
        while driver.listCount < 2 || model.state.selectedTabID == nil || model.busy, ContinuousClock.now < resumedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.state.selectedTabID == "second")
        #expect(driver.launchCount == (initialURL ? 1 : 0))
        second.cancel()
        await second.value
    }

    @Test("Adaptive portrait frames map their actual dimensions and reject legacy letterboxes")
    func mapsPortraitFrames() {
        let portrait = CGSize(width: 390, height: 700)
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 195, y: 350), in: portrait, imageSize: portrait) == CGPoint(x: 0.5, y: 0.5))
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 195, y: 10), in: portrait, imageSize: portrait) != nil)
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 195, y: 10), in: portrait) == nil)
        #expect(ChromeTabCoordinates.normalized(.zero, in: portrait, imageSize: .zero) == nil)
    }
}

private final class ResumeSelectionDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var lists = 0
    private var launches = 0
    private var selected: String?
    var listCount: Int { locked { lists } }
    var launchCount: Int { locked { launches } }
    func open() async throws {}
    func close() {}
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        locked {
            switch request.action {
            case .list: lists += 1; selected = nil
            case .select(let id): selected = id
            case .launch, .launchOffer: launches += 1; selected = "first"
            default: break
            }
            return .init(state: .init(tabs: [
                .init(id: "first", title: "First", url: "https://example.com/first"),
                .init(id: "second", title: "Second", url: "https://example.com/second")
            ], selectedTabID: selected))
        }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

#if canImport(UIKit)
@MainActor
@Suite(.serialized)
struct ChromeTabViewerRenderingTests {
    @Test("@spec CHROME-2.9: While the remote browser page is displayed, the application shall use compact browser controls and keep address and keyboard text fields hidden until the user explicitly opens them.", arguments: [320.0, 390.0])
    func compactViewerKeepsTextFieldsClosed(width: Double) async throws {
        let viewer = ChromeTabViewer(target: "pane", connectionProvider: { nil }, paneReady: false)
        let fixture = try makeFixture(viewer, width: width)
        defer { close(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        fixture.host.view.layoutIfNeeded()
        try saveRender(fixture.host.view, name: "compact-\(Int(width))")

        let views = descendants(of: fixture.host.view)
        #expect(views.compactMap { $0 as? UITextField }.isEmpty)
        #expect(views.compactMap { $0 as? UISegmentedControl }.isEmpty)
    }

    @Test("@spec CHROME-2.25: While the selected remote HTTP(S) page has no rendered frame or a current remote browser error, the application shall hide the Local/Remote toggle; when that page renders successfully, the application shall offer Local only through the toggle without a Try Local button or explanatory copy.")
    func localToggleWaitsForRenderedRemotePage() async throws {
        let model = ChromeTabViewerModel()
        let viewer = ChromeTabViewer(target: "pane", connectionProvider: { nil }, paneReady: false,
                                     onChooseLocal: { _ in }, localError: "Local browser unavailable.", model: model)
        let fixture = try makeFixture(viewer)
        defer { close(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        model.state = .init(tabs: [.init(id: "page", title: "Page", url: "https://example.com")], selectedTabID: "page")
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        model.initialLaunchError = "Earlier launch was ambiguous. Select an existing tab."
        model.image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { _ in }
        try await Task.sleep(for: .milliseconds(100))
        let modes = try #require(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.first)
        #expect(modes.numberOfSegments == 2 && modes.selectedSegmentIndex == 1)
        #expect(modes.titleForSegment(at: 0) == "Local" && modes.titleForSegment(at: 1) == "Remote")
        #expect(!descendants(of: fixture.host.view).contains { $0.accessibilityLabel == "Try Local" })
        model.error = "Remote browser failed."
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        model.error = nil
        model.state.tabs[0].url = "about:blank"
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
    }

    @Test("@spec CHROME-2.10: When the user explicitly chooses Local in the remote browser, the application shall request local presentation once without choosing Local automatically when the remote view appears.")
    func localModeRequiresExplicitChoice() async throws {
        var requests: [URL?] = []
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0,
                                   url: URL(string: "https://example.com/authorize?state=unchanged"), paneSessionName: "pane")
        let launch = ChromeTabInitialLaunch(offer: offer)
        let model = ChromeTabViewerModel()
        let driver = RenderedPageDriver(page: UIImage())
        let viewer = ChromeTabViewer(target: "pane", connectionProvider: { nil }, initialLaunch: launch,
                                     onChooseLocal: { requests.append($0) }, model: model, driverProvider: { driver })
        let fixture = try makeFixture(viewer, scenePhase: .active)
        defer { close(fixture) }
        let frameDeadline = ContinuousClock.now + .seconds(3)
        while model.image == nil, ContinuousClock.now < frameDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.image != nil)
        fixture.host.view.layoutIfNeeded()
        let current = URL(string: "https://example.com/sign-in")!
        #expect(requests.isEmpty)
        let modes = try #require(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.first)
        #expect(modes.isEnabled)
        modes.selectedSegmentIndex = 0
        modes.sendActions(for: .valueChanged)
        let deadline = ContinuousClock.now + .seconds(2)
        while requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests == [current])
        #expect(launch.action == .select(tabID: "page"))
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UITextField }.isEmpty)
    }

    @Test("A rendered browser page keeps input hidden until the keyboard is explicitly requested")
    func rendersPageWithKeyboardHiddenAndVisible() async throws {
        let page = try renderBrowserFrame()
        let model = ChromeTabViewerModel(), driver = RenderedPageDriver(page: page)
        let viewer = ChromeTabViewer(target: "pane", connectionProvider: { nil },
                                     onChooseLocal: { _ in }, model: model,
                                     driverProvider: { driver })
        let fixture = try makeFixture(viewer, scenePhase: .active)
        defer { close(fixture) }
        let connectedDeadline = ContinuousClock.now + .seconds(5)
        while (!model.frameInputEnabled || model.image == nil), ContinuousClock.now < connectedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.isConnected && model.frameInputEnabled && model.image != nil)
        try saveImage(try #require(model.image), name: "page-390-decoded-frame")
        #expect(hasInk(try #require(model.image)))
        #expect(hasBlueButton(try #require(model.image)))
        fixture.host.view.layoutIfNeeded()
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UITextField }.isEmpty)
        let hidden = try saveRender(fixture.host.view, name: "page-390-keyboard-hidden")
        #expect(hasInk(hidden, in: pageContentRect(fixture, model: model)))

        let keyboard = fixture.host.view.keyboardLayoutGuide
        if let button = descendants(of: fixture.host.view).compactMap({ $0 as? UIButton })
            .first(where: { $0.accessibilityIdentifier == "chrome-keyboard-toggle" }) {
            button.sendActions(for: .touchUpInside)
        } else {
            // This unit host does not expose SwiftUI's button as a UIButton.
            // Verify the production action and automatic focus; tap wiring needs
            // an accessibility automation test outside this hosting fixture.
            model.toggleKeyboard()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var field: UITextField?
        while (field == nil || field?.isFirstResponder != true), ContinuousClock.now < deadline {
            fixture.host.view.layoutIfNeeded()
            field = descendants(of: fixture.host.view).compactMap { $0 as? UITextField }.first
            if field?.isFirstResponder != true { try await Task.sleep(for: .milliseconds(20)) }
        }
        let input = try #require(field)
        #expect(input.isFirstResponder)
        try await Task.sleep(for: .milliseconds(350))
        fixture.host.view.layoutIfNeeded()
        let frameDeadline = ContinuousClock.now + .seconds(3)
        while (!model.frameInputEnabled || model.image == nil || model.busy
               || model.desiredViewport?.cgSize != model.frameSize), ContinuousClock.now < frameDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.frameInputEnabled && model.image != nil && !model.busy
                     && model.desiredViewport?.cgSize == model.frameSize)
        fixture.host.view.layoutIfNeeded()
        let keyboardFrame = keyboard.layoutFrame
        #expect(keyboardFrame.height > 100)
        let inputFrame = input.convert(input.bounds, to: fixture.host.view)
        // The 44-point browser toolbar sits immediately below the input row.
        #expect(inputFrame.maxY + 44 <= keyboardFrame.minY + 1)
        let visible = try saveRender(fixture.host.view, name: "page-390-keyboard-visible")
        #expect(hasInk(visible, in: pageContentRect(fixture, model: model)))
        try saveSceneRender(fixture, name: "page-390-keyboard-visible-scene")
    }

    @Test("@spec CHROME-2.14: While a host Chrome tab selection or navigation awaits acknowledgment, the application shall prevent Local browser selection and use the acknowledged selected tab's URL when Local is chosen afterward.")
    func localSelectionWaitsForHostAcknowledgment() async throws {
        let driver = LocalChoiceDriver(), model = ChromeTabViewerModel()
        var requests: [URL?] = []
        let viewer = ChromeTabViewer(target: "pane", connectionProvider: { nil },
                                     onChooseLocal: { requests.append($0) }, model: model,
                                     driverProvider: { driver })
        let fixture = try makeFixture(viewer, scenePhase: .active)
        defer { model.close(); close(fixture) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.isConnected || model.state.selectedTabID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isConnected && model.state.selectedTabID != nil)
        driver.holdNextSelection()
        let selection = Task { await model.send(.select(tabID: "new"), target: "pane") }
        defer { driver.close(); selection.cancel() }
        while !driver.hasHeldSelection, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(driver.hasHeldSelection)
        try await Task.sleep(for: .milliseconds(50))
        fixture.host.view.layoutIfNeeded()
        #expect(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        #expect(requests.isEmpty)
        driver.releaseSelection()
        #expect(await selection.value)
        try await Task.sleep(for: .milliseconds(50))
        fixture.host.view.layoutIfNeeded()
        let modes = try #require(descendants(of: fixture.host.view).compactMap { $0 as? UISegmentedControl }.first)
        #expect(modes.isEnabled)
        modes.selectedSegmentIndex = 0
        modes.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(50))
        #expect(requests == [URL(string: "https://example.com/new")])
    }

    private typealias Fixture = (window: UIWindow, host: UIHostingController<AnyView>, previous: UIWindow?)

    private func makeFixture(_ viewer: ChromeTabViewer, width: Double? = nil,
                             scenePhase: ScenePhase = .inactive) throws -> Fixture {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(viewer
            .environment(\.scenePhase, scenePhase)
            .environment(\.colorScheme, .light)))
        let window = UIWindow(windowScene: scene)
        window.frame = width.map { CGRect(x: 0, y: 0, width: $0, height: 844) } ?? scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host, previous)
    }

    private func close(_ fixture: Fixture) {
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previous?.makeKey()
    }

    @discardableResult
    private func saveRender(_ view: UIView, name: String) throws -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            #expect(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        try saveImage(image, name: name)
        return image
    }

    private func saveImage(_ image: UIImage, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/graftty-chrome-viewer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func saveSceneRender(_ fixture: Fixture, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            let windows = fixture.window.windowScene?.windows ?? [fixture.window]
            for window in windows.sorted(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue })
                where !window.isHidden && window.alpha > 0
                    && (window === fixture.window || window.windowLevel > fixture.window.windowLevel) {
                _ = window.drawHierarchy(in: window.convert(window.bounds, to: fixture.window), afterScreenUpdates: true)
            }
        }
        try saveImage(image, name: name)
    }

    private func renderBrowserFrame() throws -> UIImage {
        // The remote viewer consumes JPEG frames, not a live WebKit view.
        // Draw its input locally; HostBrowserProxyTests cover real navigation.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 700), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 700))
            let ink = UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
            ("Sign in to continue" as NSString).draw(
                in: CGRect(x: 24, y: 60, width: 342, height: 80),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: ink])
            ("Approve access with your account." as NSString).draw(
                in: CGRect(x: 24, y: 150, width: 342, height: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: ink])
            ("Email" as NSString).draw(
                at: CGPoint(x: 24, y: 250),
                withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: ink])
            UIColor.gray.setStroke()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 286, width: 342, height: 56), cornerRadius: 8).stroke()
            ("you@example.com" as NSString).draw(
                at: CGPoint(x: 36, y: 300),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: ink])
            UIColor(red: 0.14, green: 0.39, blue: 0.92, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 370, width: 342, height: 56), cornerRadius: 8).fill()
            ("Continue" as NSString).draw(
                at: CGPoint(x: 150, y: 384),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.white])
        }
        try saveImage(image, name: "page-390-browser-source")
        return image
    }

    private func descendants(of root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func pageContentRect(_ fixture: Fixture, model: ChromeTabViewerModel) -> CGRect {
        CGRect(x: 0, y: fixture.host.view.safeAreaInsets.top + 44, width: fixture.host.view.bounds.width,
               height: min(model.frameSize.height, 450))
    }

    private func hasInk(_ image: UIImage, in rect: CGRect? = nil) -> Bool {
        pixelCount(image, in: rect) { $0 < 180 && $1 < 180 && $2 < 180 } > 8
    }

    private func hasBlueButton(_ image: UIImage) -> Bool {
        pixelCount(image) { $0 < 100 && $1 < 150 && $2 > 180 } > 16
    }

    private func pixelCount(_ image: UIImage, in rect: CGRect? = nil,
                            matching: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard var source = image.cgImage else { return 0 }
        if let rect {
            guard let cropped = source.cropping(to: CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                                                           width: rect.width * image.scale, height: rect.height * image.scale)) else { return 0 }
            source = cropped
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                                          bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let pixels = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { matching(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.count
        }
    }
}

private final class RenderedPageDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let page: UIImage
    private let lock = NSLock()
    private var width = 390, height = 700
    private var viewportID: UInt64 = 1
    init(page: UIImage) { self.page = page }
    func open() async throws {}
    func close() {}
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        let dimensions = locked {
            if case .viewport(_, let newWidth, let newHeight) = request.action {
                width = newWidth; height = newHeight; viewportID += 1
            }
            return (width, height, viewportID)
        }
        let bytes = await MainActor.run {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width: dimensions.0, height: dimensions.1)
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                page.draw(at: .zero)
            }.jpegData(compressionQuality: 0.8)!
        }
        let frame = ChromeTabFrame(tabID: "page", jpeg: bytes, sequence: dimensions.2,
                                   width: dimensions.0, height: dimensions.1, viewportID: dimensions.2)
        return .init(state: .init(tabs: [.init(id: "page", title: "Sign in", url: "https://example.com/sign-in", urlTruncated: false)],
                                 selectedTabID: "page", frame: frame, canGoBack: false, canGoForward: false,
                                 width: dimensions.0, height: dimensions.1, viewportID: dimensions.2))
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class LocalChoiceDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var selected = "old"
    private var closed = false
    private var holdSelection = false
    private var held: (CheckedContinuation<ChromeTabResponse, Error>, ChromeTabResponse)?
    var hasHeldSelection: Bool { locked { held != nil } }
    func open() async throws {}
    func holdNextSelection() { locked { holdSelection = true } }
    func releaseSelection() {
        guard let response = locked({ let value = held; held = nil; return value }) else { return }
        response.0.resume(returning: response.1)
    }
    func close() {
        let continuation = locked { closed = true; let value = held?.0; held = nil; return value }
        continuation?.resume(throwing: CancellationError())
    }
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        let bytes = await MainActor.run {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 768), format: format)
                .image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768)) }
                .jpegData(compressionQuality: 0.5)!
        }
        let plan = locked { () -> (ChromeTabResponse, Bool) in
            var shouldHold = false
            if case .select(let id) = request.action {
                selected = id
                if id == "new", holdSelection { shouldHold = true; holdSelection = false }
            }
            return (.init(state: .init(tabs: [.init(id: selected, title: selected,
                                                  url: "https://example.com/" + selected, urlTruncated: false)],
                                      selectedTabID: selected, frame: .init(tabID: selected, jpeg: bytes, sequence: 1))), shouldHold)
        }
        if !plan.1 { return plan.0 }
        return try await withCheckedThrowingContinuation { continuation in
            locked {
                if closed { continuation.resume(throwing: CancellationError()) }
                else { held = (continuation, plan.0) }
            }
        }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
#endif

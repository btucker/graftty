import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
#if canImport(UIKit)
import CoreGraphics
import ImageIO
#endif
@testable import GrafttyMobileKit

struct RemoteAuthenticationOffersTests {
    @Test("@spec CHROME-2.17: If the host, worktree, pane or owner changes while a browser offer list awaits refresh, then the application shall hide the old list instead of opening its URLs in the replacement scope.")
    func offerListsRemainBoundToTheirOriginalScope() {
        let scope = TerminalBrowserRequest.Scope(hostID: UUID(), worktree: "/project", sessionName: "same-pane", ownerDeviceID: .init(value: "same-phone"))
        let offer = RemoteOpenOffer(id: UUID(), filename: "Page", byteCount: 0, url: URL(string: "https://old-host.example/"),
                                   paneSessionName: scope.sessionName, browserOwnerDeviceID: scope.ownerDeviceID)
        var snapshot = RemoteOpenPresentation.ScopedOffers()
        snapshot.update([offer], in: scope)
        #expect(snapshot.offers(in: scope) == [offer])
        for replacement in [
            TerminalBrowserRequest.Scope(hostID: UUID(), worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: "/other", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: "other", ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: .init(value: "other")),
        ] { #expect(snapshot.offers(in: replacement).isEmpty) }
        snapshot.update([], in: scope)
        #expect(snapshot.offers(in: scope).isEmpty)
    }

    @Test("@spec PORTS-5.43: When the mobile Open control has one HTTP or HTTPS resource offer, the application shall open that offer directly, and shall retain the resource menu for files or multiple offers.")
    func singleBrowserOfferOpensDirectly() throws {
        func offer(_ url: String?) throws -> RemoteOpenOffer {
            .init(id: UUID(), filename: "Resource", byteCount: 0,
                  url: try url.map { try #require(URL(string: $0)) })
        }
        let http = try offer("http://127.0.0.1:8765/viewer")
        let https = try offer("https://example.com/")
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [http]) == http)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [https]) == https)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: []) == nil)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [try offer(nil)]) == nil)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [try offer("file:///tmp/report.html")]) == nil)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [http, https]) == nil)
        #expect(RemoteOpenPresentation.directBrowserOffer(in: [http, try offer(nil)]) == nil)
    }

    @Test("@spec CHROME-2.16: When a mobile user selects an identified browser offer, the application shall reject another pane or paired device's offer instead of launching it in the currently focused pane, and shall retain explicit ordinary browsing for legacy offers without identities.")
    func manualBrowserOffersRetainTheirOrigin() {
        let owner = RemoteDeviceID(value: "phone")
        func offer(_ pane: String?, _ device: RemoteDeviceID?) -> RemoteOpenOffer {
            .init(id: UUID(), filename: "Page", byteCount: 0, url: URL(string: "https://example.com"),
                  paneSessionName: pane, browserOwnerDeviceID: device)
        }
        #expect(RemoteOpenPresentation.belongsToPane(offer("pane", owner), sessionName: "pane", ownerDeviceID: owner))
        #expect(!RemoteOpenPresentation.belongsToPane(offer("other", owner), sessionName: "pane", ownerDeviceID: owner))
        #expect(!RemoteOpenPresentation.belongsToPane(offer("pane", .init(value: "other")), sessionName: "pane", ownerDeviceID: owner))
        #expect(!RemoteOpenPresentation.belongsToPane(offer("pane", owner), sessionName: "pane", ownerDeviceID: nil))
        #expect(!RemoteOpenPresentation.belongsToPane(offer(nil, owner), sessionName: "pane", ownerDeviceID: owner))
        #expect(!RemoteOpenPresentation.belongsToPane(offer("pane", nil), sessionName: "pane", ownerDeviceID: owner))
        #expect(RemoteOpenPresentation.belongsToPane(offer(nil, nil), sessionName: "pane", ownerDeviceID: owner))
    }

    @Test func hostIdentityAndLocalizedPhoneIdentityStillRouteToPhone() {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        let hostOwner = DisplayClientID("ssh-phone-device-\(UUID().uuidString)")
        // SSH owner IDs differ from the localized UUID in phone snapshots.
        let phoneOwner = DisplayClientID(UUID().uuidString)
        #expect(hostOwner != phoneOwner)
        // RemoteOpenStore exports the paired ID, not either transport's owner UUID.
        let device = RemoteDeviceID(value: "phone-device")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                    paneSessionName: "current", browserOwnerDeviceID: device)
        var tracker = RemoteAuthenticationOffers()
        #expect(tracker.consume([offer], sessionName: "current", ownerDeviceID: RemoteDeviceID(value: "phone-device")) == offer)
    }

    @Test("@spec PORTS-5.40: While a mobile resource preview is busy, the application shall defer new sign-in offers until presentation is available and retain consumption across pane focus changes.")
    func busyPresentationDefersWithoutConsuming() {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        let owner = RemoteDeviceID(value: "phone")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                    paneSessionName: "pane", browserOwnerDeviceID: owner)
        var retainedTracker = RemoteAuthenticationOffers()
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        // Another sheet can appear while an authentication request is pending.
        retainedTracker.deferPresentation(of: offer.id)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        retainedTracker.complete(offer.id)
        // The coordinator retains this value across focus changes and route recreation.
        #expect(retainedTracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == nil)
        let secondPane = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                         paneSessionName: "second", browserOwnerDeviceID: owner)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "pane", ownerDeviceID: owner) == nil)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "second", ownerDeviceID: owner) == secondPane)
        #expect(retainedTracker.consume([offer, secondPane], sessionName: "pane", ownerDeviceID: owner) == nil)
    }

    @Test("@spec PORTS-5.37: When a new HTTP or HTTPS URL is offered by the mobile user's focused owned pane, the application shall present its host Chrome tab once and shall ignore offers from other panes, devices and followers.")
    func opensOnlyNewAuthenticationOffersForOwnedPane() throws {
        let url = URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback")!
        func offer(_ session: String?, _ url: URL) -> RemoteOpenOffer {
            .init(id: UUID(), filename: url.absoluteString, byteCount: 0, url: url, paneSessionName: session, browserOwnerDeviceID: RemoteDeviceID(value: "current-owner"))
        }
        let owner = RemoteDeviceID(value: "current-owner")
        let authentication = offer("current", url)
        let other = offer("other", url)
        let legacy = offer(nil, url)
        let ordinary = offer("current", URL(string: "https://example.com/ordinary")!)
        let wrongOwner = RemoteOpenOffer(id: UUID(), filename: url.absoluteString, byteCount: 0,
                                         url: url, paneSessionName: "current",
                                         browserOwnerDeviceID: RemoteDeviceID(value: "another-phone"))
        var tracker = RemoteAuthenticationOffers()
        #expect(tracker.consume([other, legacy, wrongOwner], sessionName: "current", ownerDeviceID: owner) == nil)
        #expect(tracker.consume([other, authentication], sessionName: "current", ownerDeviceID: owner) == authentication)
        tracker.complete(authentication.id)
        #expect(tracker.consume([authentication], sessionName: "current", ownerDeviceID: owner) == nil)
        let followerOffer = offer("current", url)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: nil) == nil)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: owner) == followerOffer)
        #expect(tracker.consume([ordinary], sessionName: "current", ownerDeviceID: owner) == ordinary)
        tracker.dismiss(ordinary.id)
        tracker.deferPresentation(of: ordinary.id)
        #expect(tracker.consume([ordinary], sessionName: "current", ownerDeviceID: owner) == nil)
        let next = offer("current", url)
        #expect(tracker.consume([next], sessionName: "current", ownerDeviceID: owner) == next)
    }
    @Test
    func queuedOrdinaryOfferRechecksOwnerAndDefersReservationBeforeLaunch() throws {
        let owner = RemoteDeviceID(value: "phone")
        let offer = RemoteOpenOffer(id: UUID(), filename: "Page", byteCount: 0,
                                   url: URL(string: "https://example.com/a?state=A%2Bb")!,
                                   paneSessionName: "pane", browserOwnerDeviceID: owner)
        var tracker = RemoteAuthenticationOffers()
        var presentation = ChromeOfferPresentation()
        // A background pane does not consume or open into the focused pane.
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(tracker.consume([offer], sessionName: "other", ownerDeviceID: owner) == nil)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: .init(value: "new-owner")) == nil)
        // A fresh host list excludes expired offers instead of trusting a queued URL.
        #expect(tracker.consume([], sessionName: "pane", ownerDeviceID: owner) == nil)
        let candidate = tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner)
        let consumed = try #require(candidate)
        #expect(presentation.begin(consumed.id) == true)
        let interruptedID = presentation.deferCurrent()
        let interrupted = try #require(interruptedID)
        tracker.deferPresentation(of: interrupted)
        let deferred = presentation.finishDismissal()
        #expect(deferred == .deferred(offer.id))
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        #expect(presentation.begin(offer.id) == true)
        if case .dismissed(let id) = presentation.finishDismissal() { tracker.dismiss(id) }
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == nil,
                "Done remains consumed after a new view/presentation is created")
    }

    @Test("@spec CHROME-2.4: When an OAuth offer awaits ownership, connection or presentation, the application shall retain its exact original URL and identity until host launch succeeds or the user dismisses it.")
    func retainsUnlaunchedAuthenticationOffer() {
        let owner = RemoteDeviceID(value: "phone")
        let url = URL(string: "https://example.com/authorize?state=A%2Bb&redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback")!
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                    paneSessionName: "pane", browserOwnerDeviceID: owner)
        var tracker = RemoteAuthenticationOffers()
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: nil) == nil)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner, canPresent: false) == nil)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == offer)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == nil)
        // Presentation failed before a launch. Releasing the reservation permits retry.
        tracker.deferPresentation(of: offer.id)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner)?.url?.absoluteString == url.absoluteString)
        tracker.complete(offer.id)
        tracker.deferPresentation(of: offer.id)
        #expect(tracker.consume([offer], sessionName: "pane", ownerDeviceID: owner) == nil)
        let dismissed = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: url,
                                        paneSessionName: "pane", browserOwnerDeviceID: owner)
        #expect(tracker.consume([dismissed], sessionName: "pane", ownerDeviceID: owner) == dismissed)
        tracker.dismiss(dismissed.id)
        tracker.deferPresentation(of: dismissed.id)
        #expect(tracker.consume([dismissed], sessionName: "pane", ownerDeviceID: owner) == nil)
    }

    @Test("@spec CHROME-2.5: When a Chrome sign-in viewer reconnects after launch acknowledgment, the application shall select its retained host tab without navigating the OAuth URL again.")
    func initialLaunchRetainsOfferAcrossViewerRestarts() {
        let url = "https://example.com/authorize?state=A%2Bb&redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback"
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0, url: URL(string: url),
                                    paneSessionName: "pane", browserOwnerDeviceID: .init(value: "phone"))
        let launch = ChromeTabInitialLaunch(offer: offer)
        #expect(launch.action == .launchOffer(id: offer.id, url: url))
        #expect(!launch.accept(.init(error: "Unavailable before dispatch")))
        #expect(launch.action == .launchOffer(id: offer.id, url: url))
        #expect(launch.accept(.init(state: .init(tabs: [.init(id: "host-tab", title: "Consent", url: "https://example.com/consent")], selectedTabID: "host-tab"))))
        #expect(launch.action == .select(tabID: "host-tab"))
        #expect(launch.offerID == offer.id)
    }

    @MainActor
    @Test("@spec CHROME-2.6: If an initial OAuth launch has an ambiguous result, then the application shall preserve working host tab selection and an explicit launch error without navigating again.", .timeLimit(.minutes(1)))
    func ambiguousLaunchRetainsManualRecovery() async throws {
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0,
                                    url: URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback"), paneSessionName: "pane")
        let model = ChromeTabViewerModel(), driver = AmbiguousOfferDriver()
        var completions = 0
        let run = Task { await model.run(target: "pane", initialLaunch: ChromeTabInitialLaunch(offer: offer), onLaunch: { completions += 1 }, makeDriver: { driver }) }
        while driver.actions().count < 2 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(await model.send(.select(tabID: "already-created"), target: "pane"))
        #expect(model.state.selectedTabID == "already-created")
        #expect(completions == 0)
        #expect(model.initialLaunchError != nil)
        #expect(driver.actions().filter { if case .launchOffer = $0 { return true }; return false }.count == 1)
        model.close(); run.cancel(); await run.value
    }

}


private final class AmbiguousOfferDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChromeTabAction] = []
    private let ambiguous: Bool
    init(ambiguous: Bool = true) { self.ambiguous = ambiguous }
    func open() async throws {}
    func close() {}
    func actions() -> [ChromeTabAction] { lock.lock(); defer { lock.unlock() }; return recorded }
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        record(request.action)
        if case .launchOffer = request.action {
            if ambiguous { return .init(error: "Ambiguous launch; select existing tab") }
            return .init(state: .init(tabs: [.init(id: "already-created", title: "Sign in", url: "https://example.com")], selectedTabID: "already-created"))
        }
        return .init(state: .init(tabs: [.init(id: "already-created", title: "Sign in", url: "https://example.com")], selectedTabID: request.action.tabID))
    }
    private func record(_ action: ChromeTabAction) { lock.lock(); recorded.append(action); lock.unlock() }
}
    @MainActor
    @Test("@spec CHROME-2.8: When a sign-in viewer resumes after scene suspension, the application shall reconnect its retained presentation and select the acknowledged host tab without sending another launch URL.", .timeLimit(.minutes(1)))
    func viewerResumesRetainedPresentation() async throws {
        let offer = RemoteOpenOffer(id: UUID(), filename: "Sign in", byteCount: 0,
                                    url: URL(string: "https://example.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback"), paneSessionName: "pane")
        let launch = ChromeTabInitialLaunch(offer: offer)
        let model = ChromeTabViewerModel(), driver = AmbiguousOfferDriver(ambiguous: false)
        var completions = 0
        let first = Task { await model.run(target: "pane", initialLaunch: launch, onLaunch: { completions += 1 }, makeDriver: { driver }) }
        while completions < 1 { await Task.yield() }
        model.close(); first.cancel(); await first.value
        let second = Task { await model.run(target: "pane", initialLaunch: launch, onLaunch: { completions += 1 }, makeDriver: { driver }) }
        while completions < 2 { await Task.yield() }
        #expect(driver.actions().filter { if case .launchOffer = $0 { return true }; return false }.count == 1)
        #expect(driver.actions().contains(.select(tabID: "already-created")))
        model.close(); second.cancel(); await second.value
    }

    @Test("@spec CHROME-2.7: While a Chrome sign-in sheet is closing, the application shall retain its presentation identity, defer automatic offers across scene interruptions, and complete only the dismissed offer before accepting another.")
    func dismissalCannotConsumeReplacementOffer() {
        var presentation = ChromeOfferPresentation()
        let first = UUID(), second = UUID()
        #expect(presentation.begin(first) == true)
        // Scene readiness changes stop polling and transport without ending presentation.
        #expect(!presentation.canPresent)
        #expect(presentation.begin(second) == false)
        #expect(presentation.finishDismissal() == .dismissed(first))
        #expect(presentation.begin(second) == true)
        #expect(presentation.deferCurrent() == second)
        #expect(!presentation.canPresent)
        #expect(presentation.finishDismissal() == .deferred(second))
        #expect(presentation.canPresent)
    }

@MainActor
struct ChromeViewportModelTests {
    @Test("@spec CHROME-2.11: When browser geometry changes, the application shall block image input immediately and accept only a fresh frame matching the acknowledged viewport and selected tab.")
    func resizeRejectsHeldOldFrame() async throws {
        let model = ChromeTabViewerModel(), driver = ViewportDriver()
        let run = Task { await model.run(target: "pane", initialLaunch: nil, onLaunch: {}, makeDriver: { driver }) }
        defer { model.close(); run.cancel() }
        #expect(try await waitUntil { model.frameInputEnabled })
        driver.holdNextFrame()
        let held = Task { await model.send(.frame(tabID: "page"), target: "pane", polling: true) }
        #expect(try await waitUntil { driver.hasHeldFrame })
        model.requestViewport(CGSize(width: 390, height: 700), target: "pane")
        #expect(!model.frameInputEnabled)
        let tap = Task { await model.send(.tap(tabID: "page", x: 0.5, y: 0.5), target: "pane") }
        await Task.yield()
        driver.releaseFrame()
        _ = await held.value
        #expect(!(await tap.value))
        #expect(!model.frameInputEnabled)
        #expect(try await waitUntil { driver.viewportActions.count == 1 })
        #expect(try await waitUntil { model.state.width == 390 })
        #expect(await model.send(.frame(tabID: "page"), target: "pane", polling: true))
        #expect(model.frameInputEnabled)
        #expect(model.frameSize == CGSize(width: 390, height: 700))
        #expect(driver.tapCount == 0)
        model.close(); run.cancel(); await run.value
    }

    @Test("@spec CHROME-2.12: While a viewport resize is in flight, the application shall retain only the latest requested geometry without canceling the connection, and shall discard pending resize work when the viewer closes.")
    func replacesPendingGeometryAndCancelsOnClose() async throws {
        let model = ChromeTabViewerModel(), driver = ViewportDriver()
        let run = Task { await model.run(target: "pane", initialLaunch: nil, onLaunch: {}, makeDriver: { driver }) }
        defer { model.close(); run.cancel() }
        #expect(try await waitUntil { model.frameInputEnabled })
        driver.holdNextViewport()
        model.requestViewport(CGSize(width: 390, height: 700), target: "pane")
        try #require(try await waitUntil { driver.hasHeldViewport })
        model.requestViewport(CGSize(width: 320, height: 500), target: "pane")
        model.requestViewport(CGSize(width: 420, height: 800), target: "pane")
        #expect(driver.closeCount == 0)
        driver.releaseViewport()
        #expect(try await waitUntil { driver.viewportActions.count == 2 })
        #expect(driver.viewportActions == [.viewport(tabID: "page", width: 390, height: 700),
                                           .viewport(tabID: "page", width: 420, height: 800)])
        driver.holdNextViewport()
        model.requestViewport(CGSize(width: 380, height: 600), target: "pane")
        try #require(try await waitUntil { driver.hasHeldViewport })
        model.requestViewport(CGSize(width: 340, height: 550), target: "pane")
        model.close(); run.cancel(); await run.value
        #expect(driver.closeCount > 0)
        #expect(driver.viewportActions.count == 3)
        #expect(!model.frameInputEnabled)
    }

    @Test("A selected-tab change retains one tracked pending resize and close cancels its replacement")
    func selectionRetainsSinglePendingResize() async throws {
        let model = ChromeTabViewerModel(), driver = ViewportDriver()
        let run = Task { await model.run(target: "pane", initialLaunch: nil, onLaunch: {}, makeDriver: { driver }) }
        defer { model.close(); run.cancel() }
        try #require(try await waitUntil { model.frameInputEnabled })
        model.requestViewport(CGSize(width: 390, height: 700), target: "pane")
        #expect(await model.send(.select(tabID: "other"), target: "pane"))
        driver.holdNextViewport()
        // The original debounce wakes at 120ms and schedules the selected tab's
        // replacement; update geometry while that replacement is still pending.
        try await Task.sleep(for: .milliseconds(160))
        model.requestViewport(CGSize(width: 430, height: 810), target: "pane")
        try #require(try await waitUntil { driver.hasHeldViewport })
        try await Task.sleep(for: .milliseconds(150))
        driver.releaseViewport()
        try #require(try await waitUntil { model.state.width == 430 })
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.viewportActions == [.viewport(tabID: "other", width: 430, height: 810)])
        driver.holdNextViewport()
        model.requestViewport(CGSize(width: 400, height: 600), target: "pane")
        try #require(try await waitUntil { driver.hasHeldViewport })
        model.requestViewport(CGSize(width: 320, height: 500), target: "pane")
        model.close(); run.cancel(); await run.value
        #expect(driver.viewportActions.count == 2)
        #expect(!model.frameInputEnabled)
    }

    @Test("Unchanged browser geometry is restored after the connection resumes")
    func unchangedGeometryRestoresAfterReconnect() async throws {
        let model = ChromeTabViewerModel(), firstDriver = ViewportDriver()
        model.requestViewport(CGSize(width: 390, height: 700), target: "pane")
        let first = Task { await model.run(target: "pane", initialLaunch: nil, onLaunch: {}, makeDriver: { firstDriver }) }
        defer { model.close(); first.cancel() }
        try #require(try await waitUntil { model.frameInputEnabled && model.frameSize == CGSize(width: 390, height: 700) })
        model.close(); first.cancel(); await first.value
        let nextDriver = ViewportDriver()
        let resumed = Task { await model.run(target: "pane", initialLaunch: nil, onLaunch: {}, makeDriver: { nextDriver }) }
        defer { model.close(); resumed.cancel() }
        try #require(try await waitUntil { model.frameInputEnabled && model.frameSize == CGSize(width: 390, height: 700) })
        #expect(nextDriver.viewportActions == [.viewport(tabID: "page", width: 390, height: 700)])
        model.close(); resumed.cancel(); await resumed.value
    }

    @Test("@spec CHROME-2.13: When the user requests the browser keyboard, the application shall expose keyboard input through observable presentation state and hide it when the viewer closes.")
    func keyboardRequiresAnExplicitAction() {
        let model = ChromeTabViewerModel()
        #expect(!model.keyboardPresented)
        model.toggleKeyboard()
        #expect(model.keyboardPresented)
        model.close()
        #expect(!model.keyboardPresented)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
}

private final class ViewportDriver: ChromeTabChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [ChromeTabAction] = []
    private var width = 1024, height = 768
    private var selectedTabID = "page"
    private var viewportID: UInt64 = 1
    private var holdFrame = false, holdViewport = false
    private var frameWaiter: (CheckedContinuation<ChromeTabResponse, Error>, ChromeTabResponse)?
    private var viewportWaiter: (CheckedContinuation<ChromeTabResponse, Error>, ChromeTabResponse)?
    private var closed = false, closes = 0
    var viewportActions: [ChromeTabAction] { locked { actions.filter { if case .viewport = $0 { return true }; return false } } }
    var tapCount: Int { locked { actions.filter { if case .tap = $0 { return true }; return false }.count } }
    var closeCount: Int { locked { closes } }
    var hasHeldFrame: Bool { locked { frameWaiter != nil } }
    var hasHeldViewport: Bool { locked { viewportWaiter != nil } }
    func open() async throws {}
    func holdNextFrame() { locked { holdFrame = true } }
    func holdNextViewport() { locked { holdViewport = true } }
    func releaseFrame() { let entry = locked { let value = frameWaiter; frameWaiter = nil; return value }; entry?.0.resume(returning: entry!.1) }
    func releaseViewport() { let entry = locked { let value = viewportWaiter; viewportWaiter = nil; return value }; entry?.0.resume(returning: entry!.1) }
    func close() {
        let entries = locked {
            closes += 1; closed = true
            let values = [frameWaiter, viewportWaiter].compactMap { $0 }
            frameWaiter = nil; viewportWaiter = nil
            return values
        }
        for entry in entries { entry.0.resume(throwing: CancellationError()) }
    }
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        let plan = locked { () -> (response: ChromeTabResponse, held: Int) in
            actions.append(request.action)
            var held = 0, frame = true
            if case .select(let id) = request.action { selectedTabID = id }
            if case .viewport(_, let newWidth, let newHeight) = request.action {
                width = newWidth; height = newHeight; viewportID += 1; frame = false
                if holdViewport { holdViewport = false; held = 2 }
            } else if case .frame = request.action, holdFrame { holdFrame = false; held = 1 }
            let image = frame ? ChromeTabFrame(tabID: selectedTabID, jpeg: Self.jpeg(width: width, height: height), sequence: viewportID,
                                               width: width, height: height, viewportID: viewportID) : nil
            return (.init(state: .init(tabs: [.init(id: selectedTabID, title: "Page", url: "https://example.com")],
                                      selectedTabID: selectedTabID, frame: image, width: width, height: height, viewportID: viewportID)), held)
        }
        if plan.held == 0 { return plan.response }
        return try await withCheckedThrowingContinuation { continuation in
            locked {
                if closed { continuation.resume(throwing: CancellationError()) }
                else if plan.held == 1 { frameWaiter = (continuation, plan.response) }
                else { viewportWaiter = (continuation, plan.response) }
            }
        }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private static func jpeg(width: Int, height: Int) -> Data {
        #if canImport(UIKit)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return bytes as Data
        #else
        return Data([1])
        #endif
    }
}

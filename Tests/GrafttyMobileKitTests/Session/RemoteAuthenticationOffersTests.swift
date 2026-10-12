import Foundation
import Testing
import GrafttyProtocol
import GrafttyRemoteClient
@testable import GrafttyMobileKit

struct RemoteAuthenticationOffersTests {
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

    @Test("@spec PORTS-5.37: When a new OAuth URL is offered by the mobile user's currently owned pane, the application shall present host Chrome sign-in on that mobile device once and shall ignore offers from other panes, followers, and ordinary URLs.")
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
        #expect(tracker.consume([other, legacy, ordinary, wrongOwner], sessionName: "current", ownerDeviceID: owner) == nil)
        #expect(tracker.consume([other, authentication], sessionName: "current", ownerDeviceID: owner) == authentication)
        tracker.complete(authentication.id)
        #expect(tracker.consume([authentication], sessionName: "current", ownerDeviceID: owner) == nil)
        let followerOffer = offer("current", url)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: nil) == nil)
        #expect(tracker.consume([followerOffer], sessionName: "current", ownerDeviceID: owner) == followerOffer)
        let next = offer("current", url)
        #expect(tracker.consume([next], sessionName: "current", ownerDeviceID: owner) == next)
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

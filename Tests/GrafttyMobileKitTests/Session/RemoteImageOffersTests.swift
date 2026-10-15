import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

struct RemoteImageOffersTests {
    @Test("@spec PREVIEW-2.1: When file preview offers arrive on mobile, the application shall select the latest preview for its owning pane and device, recognize legacy image intent, and exclude both from Browser resources.")
    func selectsFilesAndLegacyImages() {
        let legacy = image()
        let html = RemoteOpenOffer(id: UUID(), filename: "explanation.html", byteCount: 4,
                                   paneSessionName: "pane", previewKind: "file", previewOwnerDeviceID: scope.ownerDeviceID)
        let other = RemoteOpenOffer(id: UUID(), filename: "other.pdf", byteCount: 4,
                                    paneSessionName: "other", previewKind: "file", previewOwnerDeviceID: scope.ownerDeviceID)
        #expect(RemoteImageOffers.latest(in: [legacy, html, other], scope: scope) == html)
        #expect(RemoteImageOffers.browserResources(in: [legacy, html, other]).isEmpty)
    }
    @Test("@spec PREVIEW-2.5: When multiple files share a native preview collection identity, mobile shall retain request order and exclude files from other collections, panes or devices.")
    func selectsLatestCollectionInOrder() {
        let group = UUID()
        let files = ["one.html", "two.pdf"].map {
            RemoteOpenOffer(id: UUID(), filename: $0, byteCount: 4, paneSessionName: "pane",
                            previewKind: "file", previewOwnerDeviceID: scope.ownerDeviceID, previewGroupID: group)
        }
        let unrelated = image()
        #expect(RemoteImageOffers.collection(in: [unrelated] + files, scope: scope) == files)
        #expect(RemoteImageOffers.collection(in: files + [unrelated], scope: scope) == [unrelated])
    }

    private let scope = TerminalBrowserRequest.Scope(hostID: UUID(), worktree: "/project", sessionName: "pane", ownerDeviceID: .init(value: "phone"))

    private func image(_ name: String = "image.png", pane: String = "pane", owner: String = "phone") -> RemoteOpenOffer {
        .init(id: UUID(), filename: name, byteCount: 4, paneSessionName: pane,
              previewKind: "image", previewOwnerDeviceID: .init(value: owner))
    }

    @Test("@spec IMAGE-2.2: When image offers arrive for a focused owned mobile pane, the application shall expose only the latest image intended for that pane and device through Images and retain absent or unknown intent in Browser resources.")
    func selectsLatestIntendedImageWithoutCapturingOrdinaryFiles() {
        let old = image("old.png"), latest = image("latest.png")
        let file = RemoteOpenOffer(id: UUID(), filename: "ordinary.png", byteCount: 4)
        let future = RemoteOpenOffer(id: UUID(), filename: "future.png", byteCount: 4, previewKind: "future")
        let offers = [old, file, latest, image(pane: "other"), image(owner: "other"), future]
        #expect(RemoteImageOffers.latest(in: offers, scope: scope) == latest)
        #expect(RemoteImageOffers.browserResources(in: offers) == [file, future])
        let follower = TerminalBrowserRequest.Scope(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: nil)
        #expect(RemoteImageOffers.latest(in: offers, scope: follower) == nil)
    }

    @Test("@spec IMAGE-2.3: If an image download or presentation loses its original host, worktree, pane, device, focus, ownership or latest offer, then the application shall reject its completion and cancel the stale preview.")
    func rejectsStaleImageCompletion() {
        let offer = image()
        let request = RemoteImageOffers.Request(offer: offer, scope: scope)
        #expect(request.isCurrent(latest: offer, scope: scope, isReady: true))
        #expect(!request.isCurrent(latest: image(), scope: scope, isReady: true))
        #expect(!request.isCurrent(latest: nil, scope: scope, isReady: true))
        #expect(!request.isCurrent(latest: offer, scope: scope, isReady: false))
        for changed in [
            TerminalBrowserRequest.Scope(hostID: UUID(), worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: "/other", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: "other", ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: .init(value: "other"))
        ] {
            #expect(!request.isCurrent(latest: offer, scope: changed, isReady: true))
        }
    }
}

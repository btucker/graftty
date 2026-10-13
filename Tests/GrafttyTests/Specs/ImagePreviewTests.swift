import AppKit
import Foundation
import Testing
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import GrafttyProtocol
import GrafttyKit
@testable import Graftty

@MainActor
struct ImagePreviewTests {
    @Test("@spec IMAGE-1.3: When a pane requests a native image preview, the application shall replace only that pane's preview, retain a bounded number of previews, and dismiss only the requested pane.")
    func scopesReplacementAndDismissal() throws {
        let store = ImagePreviewStore()
        let a = PaneSlotID(id: UUID()), b = PaneSlotID(id: UUID())
        let image = try fixture()
        store.present(image, filename: "a.png", for: a)
        store.present(image, filename: "b.png", for: b)
        store.present(image, filename: "new.png", for: a)
        #expect(store.previews.count == 2)
        #expect(store.previews[a]?.filename == "new.png")
        #expect(store.previews[b]?.filename == "b.png")
        store.dismiss(a)
        #expect(store.previews[a] == nil)
        #expect(store.previews[b] != nil)
        for _ in 0..<20 { store.present(image, filename: "x", for: PaneSlotID(id: UUID())) }
        #expect(store.previews.count == ImagePreviewStore.maximumPreviews)
    }

    @Test("@spec IMAGE-1.4: When a native image tray renders, the application shall overlay at most 45 percent of the pane height and 360 points without resizing the terminal, fit the image with its aspect ratio, and bound zoom from fit to eight times fit.")
    func boundsLayoutAndZoom() {
        #expect(ImagePreviewLayout.trayHeight(paneHeight: 800) == 360)
        #expect(ImagePreviewLayout.trayHeight(paneHeight: 200) == 90)
        #expect(ImagePreviewLayout.trayHeight(paneHeight: 0) == 0)
        #expect(ImagePreviewLayout.fit(image: CGSize(width: 800, height: 400), viewport: CGSize(width: 200, height: 200)) == CGSize(width: 200, height: 100))
        #expect(ImagePreviewLayout.clampZoom(100) == 8)
        #expect(ImagePreviewLayout.clampZoom(0) == 1)
    }

    @Test("@spec IMAGE-1.5: When the application loads an image preview, it shall reject missing, nonregular, invalid, or larger than 20 MB files and decode only the oriented first frame with a maximum edge of 2048 pixels.")
    func boundsDecodeAndRejectsInvalidFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.png")
        #expect(throws: (any Error).self) { try ImagePreviewLoader.load(missing) }
        #expect(throws: (any Error).self) { try ImagePreviewLoader.load(root) }
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try ImagePreviewLoader.load(invalid) }
        let big = root.appendingPathComponent("large.png")
        try Data(count: 20 * 1024 * 1024 + 1).write(to: big)
        #expect(throws: (any Error).self) { try ImagePreviewLoader.load(big) }
        let valid = root.appendingPathComponent("valid.png")
        let bitmap = NSBitmapImageRep(cgImage: try fixture(width: 3000, height: 100))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: valid)
        let decoded = try ImagePreviewLoader.load(valid)
        #expect(decoded.width == 2048)
        #expect(decoded.height < 100)
        let pdf = root.appendingPathComponent("chart.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        let pdfImage = try ImagePreviewLoader.load(pdf)
        #expect(pdfImage.width <= 2048)
        #expect(pdfImage.width == pdfImage.height * 2)
        let rotated = root.appendingPathComponent("rotated.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try fixture(width: 30, height: 10), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let oriented = try ImagePreviewLoader.load(rotated)
        #expect(oriented.width == 10 && oriented.height == 30)
        let animated = root.appendingPathComponent("animated.gif")
        let gif = try #require(CGImageDestinationCreateWithURL(animated as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(gif, try fixture(width: 30, height: 10), nil)
        CGImageDestinationAddImage(gif, try fixture(width: 30, height: 10), nil)
        #expect(CGImageDestinationFinalize(gif))
        let first = try ImagePreviewLoader.load(animated)
        #expect(first.width == 30 && first.height == 10)
    }

    @Test("@spec IMAGE-1.7: When an image tray arrives or closes, the application shall preserve terminal focus, and shall dismiss on Escape only when the preview owns focus, restoring its previous responder.")
    func nativeControlsPreserveFocusAndScopeEscape() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        let terminal = ImagePreviewTerminalFixture(frame: root.bounds)
        root.addSubview(terminal)
        window.contentView = root
        #expect(window.makeFirstResponder(terminal))
        var dismissed = 0
        let tray = NativeImagePreviewTray(preview: .init(image: try fixture(), filename: "chart.png"), onDismiss: { dismissed += 1 })
        tray.frame = NSRect(x: 0, y: 330, width: 800, height: 270)
        root.addSubview(tray)
        tray.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === terminal)
        tray.cancelOperation(nil)
        #expect(dismissed == 0)
        tray.closePreview()
        #expect(dismissed == 1)
        #expect(window.firstResponder === terminal)
        tray.claimFocus()
        #expect(tray.ownsFocus)
        for _ in 0..<20 { tray.zoomIn() }
        #expect(tray.scrollView.magnification == 8)
        #expect(tray.scrollView.documentVisibleRect.width < tray.scrollView.contentSize.width)
        tray.fit()
        #expect(tray.scrollView.magnification == 1)
        #expect(tray.scrollView.frame.height == 234)
        tray.updatePreview(.init(image: try fixture(width: 30, height: 40), filename: "second.png"))
        #expect(tray.ownsFocus)
        #expect(tray.scrollView.magnification == 1)
        tray.cancelOperation(nil)
        #expect(dismissed == 2)
        #expect(window.firstResponder === terminal)
    }

    @Test("@spec IMAGE-1.8: While panes are split or worktrees are switched, the native tray shall show only the focused or visible zoomed pane's image and retain inactive previews without replacing it.")
    func selectsFocusedAndZoomedPreviewAcrossTrees() throws {
        let a = PaneSlotID(id: UUID()), b = PaneSlotID(id: UUID()), c = PaneSlotID(id: UUID())
        var tree = SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(a), right: .leaf(b))))
        let other = SplitTree(root: .leaf(c))
        let store = ImagePreviewStore()
        let image = try fixture()
        store.present(image, filename: "a", for: a)
        store.present(image, filename: "b", for: b)
        #expect(ImagePreviewLayout.visiblePane(tree: tree, focused: a) == a)
        #expect(store.previews[try #require(ImagePreviewLayout.visiblePane(tree: tree, focused: a))]?.filename == "a")
        #expect(ImagePreviewLayout.visiblePane(tree: tree, focused: b) == b)
        tree = SplitTree(root: tree.root, zoomed: a)
        #expect(ImagePreviewLayout.visiblePane(tree: tree, focused: b) == a)
        #expect(ImagePreviewLayout.visiblePane(tree: other, focused: a) == c)
        #expect(store.previews[c] == nil)
    }

    @Test("@spec IMAGE-1.11: While the native image tray is visible, the application shall keep terminal content below it clickable and at its original size.")
    func overlayPreservesTerminalHitTestingAndSize() throws {
        _ = NSApplication.shared
        let terminal = ImagePreviewTerminalFixture(frame: .zero)
        let pane = PaneSlotID(id: UUID())
        let preview = ImagePreviewStore.Preview(image: try fixture(), filename: "chart.png")
        let hosted = NSHostingView(rootView: ImagePreviewTerminalRepresentable(view: terminal)
            .overlay(alignment: .top) { ImagePreviewOverlay(pane: pane, preview: preview, onDismiss: {}) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        let point = terminal.convert(NSPoint(x: 400, y: 100), to: hosted.superview)
        let hit = try #require(hosted.hitTest(point))
        #expect(hit === terminal || hit.isDescendant(of: terminal), "Hit \(type(of: hit)) at \(point)")
        #expect(terminal.bounds.size == CGSize(width: 800, height: 600))
        let trays = descendants(hosted).compactMap { $0 as? NativeImagePreviewTray }
        let tray = try #require(trays.first)
        #expect(trays.count == 1)
        #expect(tray.bounds.height == 270)
        #expect(tray.bounds.width == 800)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test("@spec IMAGE-1.9: When preview decoding finishes after a newer request or dismissal, the application shall discard the older result instead of replacing or resurrecting the pane preview.")
    func rejectsStaleGeneration() {
        let store = ImagePreviewStore(), pane = PaneSlotID(id: UUID())
        let old = store.beginRequest(for: pane)
        let current = store.beginRequest(for: pane)
        #expect(!store.isCurrent(old, for: pane))
        #expect(store.isCurrent(current, for: pane))
        store.finishRequest(old, for: pane)
        #expect(store.isCurrent(current, for: pane))
        store.dismiss(pane)
        #expect(!store.isCurrent(current, for: pane))
    }

    @Test("@spec IMAGE-1.10: When graftty image identifies its originating pane, the application shall use registered session membership after directory changes, route iOS leadership to native mobile offers, and reject unsupported or other Mac leaders without opening on the host Mac.")
    func resolvesOriginAndRespectsDisplayLeader() throws {
        let a = PaneSlotID(id: UUID()), b = PaneSlotID(id: UUID())
        let session = PaneSessionID(id: UUID())
        var worktree = WorktreeEntry(path: "/project/a", branch: "a")
        worktree.splitTree = SplitTree(root: .leaf(a))
        worktree.paneSessions[a] = session
        worktree.focusedPaneSlotID = a
        var other = WorktreeEntry(path: "/project/b", branch: "b")
        other.splitTree = SplitTree(root: .leaf(b))
        let state = AppState(repos: [RepoEntry(path: "/project", displayName: "P", worktrees: [worktree, other])])
        let name = ZmxLauncher.sessionName(for: session)
        let scope = try #require(ImagePreviewRouting.scope(path: other.path, paneSessionName: name, state: state))
        #expect(scope.pane == a)
        #expect(scope.worktreePath == worktree.path)
        #expect(ImagePreviewRouting.scope(path: worktree.path, paneSessionName: "unknown", state: state) == nil)
        #expect(ImagePreviewRouting.destination(ownerKind: .ios, macIsFollower: true) == .mobile)
        #expect(ImagePreviewRouting.destination(ownerKind: .mac, macIsFollower: true) == .unavailable)
        #expect(ImagePreviewRouting.destination(ownerKind: .web, macIsFollower: true) == .unavailable)
        #expect(ImagePreviewRouting.destination(ownerKind: .mac, macIsFollower: false) == .mac)
        #expect(ImagePreviewRouting.destination(ownerKind: nil, macIsFollower: true) == .unavailable)
        #expect(ImagePreviewRouting.destination(ownerKind: nil, macIsFollower: false) == .mac)
    }

    @Test("@spec IMAGE-1.12: When a mobile leader receives an image request, the application shall offer the validated file snapshot for its originating pane, replacing that pane's previous image offer without rereading a changed file.")
    func mobileOfferUsesValidatedSnapshotAndReplacesOnlyOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(cgImage: try fixture())
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: root)
        let snapshot = try ImagePreviewLoader.snapshot(root)
        try Data("changed file".utf8).write(to: root)
        let store = RemoteOpenStore()
        _ = try await store.offerSnapshot(bytes: bytes, filename: "old.png", worktree: "/a", paneSessionName: "pane-a", previewRevision: 1)
        let other = try await store.offerSnapshot(bytes: bytes, filename: "other.png", worktree: "/a", paneSessionName: "pane-b")
        let offer = try await store.offerSnapshot(bytes: snapshot.bytes, filename: "new.png", worktree: "/a", paneSessionName: "pane-a", previewRevision: 2)
        await #expect(throws: RemoteOpenStore.Failure.superseded) {
            try await store.offerSnapshot(bytes: snapshot.bytes, filename: "stale.png", worktree: "/a", paneSessionName: "pane-a", previewRevision: 1)
        }
        let fileOffer = try await store.offerSnapshot(bytes: bytes, filename: "report.png", worktree: "/a", paneSessionName: "pane-a")
        #expect(offer.paneSessionName == "pane-a")
        #expect(await store.list(worktree: "/a") == [other, offer, fileOffer])
        #expect(try await store.read(id: offer.id, worktree: "/a", offset: 0) == bytes)
        await store.withdraw(id: offer.id, worktree: "/other")
        #expect(await store.list(worktree: "/a") == [other, offer, fileOffer])
        await store.withdraw(id: offer.id, worktree: "/a")
        #expect(await store.list(worktree: "/a") == [other, fileOffer])
    }

    @Test("@spec IMAGE-1.13: When an image request reaches the application, it shall offer validated bytes to an iOS pane leader and leave the host tray unchanged, while unavailable leaders and invalid origins shall return errors.")
    func applicationRoutesMobileWithoutHostTray() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try #require(NSBitmapImageRep(cgImage: try fixture()).representation(using: .png, properties: [:]))
        try bytes.write(to: url)
        let pane = PaneSlotID(id: UUID()), session = PaneSessionID(id: UUID())
        var worktree = WorktreeEntry(path: "/image-tests/\(UUID().uuidString)", branch: "test")
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions[pane] = session
        let state = AppState(repos: [RepoEntry(path: "/image-tests", displayName: "Image", worktrees: [worktree])])
        let name = ZmxLauncher.sessionName(for: session)
        let manager = TerminalManager(socketPath: "/tmp/unused-image-test-socket")
        let ownership = SessionDisplayOwnershipStore()
        manager.displayOwnershipStore = ownership
        let phone = DisplayClientID("phone"), grid = try DisplayGrid(cols: 80, rows: 24)
        _ = ownership.attachClient(sessionName: name, clientID: phone, kind: .ios, role: .interactive, visible: true, grid: grid)
        _ = ownership.claimOwner(sessionName: name, clientID: phone, kind: .ios, grid: grid)
        let response = await ImagePreviewRequest.handle(path: worktree.path, target: url.path, paneSessionName: name,
                                                        state: { state }, terminalManager: manager)
        #expect(response == .ok)
        #expect(ImagePreviewStore.shared.previews[pane] == nil)
        let offers = await RemoteOpenStore.shared.list(worktree: worktree.path)
        let offer = try #require(offers.first)
        #expect(offer.paneSessionName == name)
        #expect(try await RemoteOpenStore.shared.read(id: offer.id, worktree: worktree.path, offset: 0) == bytes)
        await RemoteOpenStore.shared.withdraw(id: offer.id, worktree: worktree.path)
        _ = ownership.releaseOwner(sessionName: name, clientID: phone)
        let unavailable = await ImagePreviewRequest.handle(path: worktree.path, target: url.path, paneSessionName: name,
                                                           state: { state }, terminalManager: manager)
        guard case .error = unavailable else { Issue.record("Absent local surface should fail closed"); return }
        let unknown = await ImagePreviewRequest.handle(path: worktree.path, target: url.path, paneSessionName: "unknown",
                                                       state: { state }, terminalManager: manager)
        guard case .error = unknown else { Issue.record("Unknown pane should reject preview"); return }
    }

    private func fixture(width: Int = 20, height: Int = 10) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try #require(context.makeImage())
    }
}

@MainActor
private final class ImagePreviewTerminalFixture: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct ImagePreviewTerminalRepresentable: NSViewRepresentable {
    let view: ImagePreviewTerminalFixture
    func makeNSView(context: Context) -> ImagePreviewTerminalFixture { view }
    func updateNSView(_ view: ImagePreviewTerminalFixture, context: Context) {}
}

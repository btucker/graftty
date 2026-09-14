import CryptoKit
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
import SwiftUI
import AppKit
import GrafttyCommandUI

@testable import Graftty
@testable import GrafttyKit

@Suite("Remote Macs sidebar and add sheet")
@MainActor
struct RemoteMacsSidebarTests {
    @Test("@spec LAYOUT-2.55: While the Remote Macs menu is open, the application shall show machine connection status and offer connection actions only for unavailable machines.")
    func machineStatusActions() {
        #expect(RemoteMacConnectionState.connected.statusText == "Connected")
        #expect(RemoteMacConnectionState.connected.connectionActionTitle == nil)
        #expect(RemoteMacConnectionState.connecting.statusText == "Connecting…")
        #expect(RemoteMacConnectionState.connecting.connectionActionTitle == nil)
        #expect(RemoteMacConnectionState.offline.connectionActionTitle == "Connect")
        #expect(RemoteMacConnectionState.discovered.connectionActionTitle == "Connect")
        #expect(RemoteMacConnectionState.failed.connectionActionTitle == "Retry")
        #expect(RemoteMacConnectionState.needsPairing.connectionActionTitle == "Pair…")
    }

    @Test("@spec LAYOUT-2.54: While the project column is enabled, the application shall align remote worktrees with the project column's row margins and height without reserving rows for Mac or repository headings.")
    func projectColumnRemovesRemoteHierarchy() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteMacStore(storeURL: directory.appendingPathComponent("remotes.json"))
        let remote = try makeRemoteMac(label: "Studio Mac")
        try store.add(remote)
        let model = RemoteMacsModel(store: store)
        await model.loadSavedRemotes()
        let row = makeWorktreePanes(path: "/repo/feature", displayName: "feature",
            layout: .leaf(sessionName: "shell", title: "shell", attentionText: nil, isBusy: false, attentionSource: nil))
        let project = SidebarProject(id: "p", repositoryID: "r", name: "graftty",
            owner: .init(deviceID: remote.id, deviceLabel: remote.label, relayDepth: 0))
        let content = HStack(spacing: 0) {
            ProjectNavigationRail(projects: [project], counts: [:], icons: [:], selectedID: "p", showsAttention: false,
                collapsed: .constant(false), selectionColor: Color.white.opacity(0.16),
                onSelect: { _ in }, onAttention: {}, onMove: { _, _, _ in })
            Divider()
            ProjectWorktreeColumn {
                RemoteMacsSection(model: model, worktreePanesByRemote: [RemoteMacIdentity(remote): [row]],
                    selectedRemoteIdentity: RemoteMacIdentity(remote), selectedRemoteWorktreePath: row.path,
                    theme: .fallback, onSelectRemoteMac: { _ in }, onAddRemoteMac: {},
                    showsMacHierarchy: false, showsRepositoryHeaders: false)
            }.frame(width: 260)
            Divider()
            ProjectWorktreeColumn {
                let entry = WorktreeEntry(path: "/local/feature", branch: "feature")
                let node = SidebarWorktreeNode.worktree(entry, displayName: "feature")
                SidebarWorktreeNodeRow(node: node, depth: 0, repositoryID: UUID(), expansion: .constant(.init()),
                    statsByWorktreePath: [:], theme: .fallback, projectColumn: true) { entry, name in
                    WorktreeRow(entry: entry, isActive: true, displayName: name, isMainCheckout: false,
                        theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
                        .frame(minHeight: 44)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                }.modifier(SidebarWorktreeRowInsets(node: node, depth: 0, projectColumn: true))
                SidebarWorktreeNodeRow(node: .folder(path: "topic", name: "topic", children: [node]), depth: 0,
                    repositoryID: UUID(), expansion: .constant(.init()), statsByWorktreePath: [:], theme: .fallback,
                    projectColumn: true) { entry, name in
                    WorktreeRow(entry: entry, isActive: false, displayName: name, isMainCheckout: false,
                        theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
                        .frame(minHeight: 44)
                }
            }.frame(width: 260)
        }.frame(height: 400).background(Color(red: 0.13, green: 0.14, blue: 0.16)).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 718, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        #expect(table(in: hosting) == nil)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        for columnStart in [197, 458] {
            let firstHighlight = try #require((0..<260).first { x in
                let color = bitmap.colorAt(x: Int(CGFloat(columnStart + x) * scale), y: Int(23 * scale))?.usingColorSpace(.deviceRGB)
                return (color?.redComponent ?? 0) > 0.2
            })
            #expect(abs(firstHighlight - 6) <= 1)
        }
        if let path = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("project-worktree-spacing.png"))
            let menuHost = NSHostingView(rootView: RemoteMacConnectionsPopover(model: model, onAddRemoteMac: {})
                .background(Color(red: 0.13, green: 0.14, blue: 0.16)).environment(\.colorScheme, .dark))
            let menuWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: 165), styleMask: .borderless, backing: .buffered, defer: false)
            menuWindow.contentView = menuHost
            menuWindow.orderFront(nil)
            defer { menuWindow.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            menuHost.layoutSubtreeIfNeeded()
            let menuBitmap = try #require(menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds))
            menuHost.cacheDisplay(in: menuHost.bounds, to: menuBitmap)
            try menuBitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("remote-mac-menu.png"))
        }
    }

    @Test("@spec LAYOUT-2.44: If the owning Mac does not advertise worktree editing, then the application shall disable remote worktree reorder actions.")
    func reorderRequiresOwningHostCapability() {
        let row = WorktreePanes(path: "/feature", displayName: "feature", repoDisplayName: "Project", displayBranch: "feature", state: .closed,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: .init(id: "worktree", projectID: "project"))
        #expect(!RemoteWorktreeReorderPolicy.allows(row, editableProjectIDs: [], query: ""))
        #expect(RemoteWorktreeReorderPolicy.allows(row, editableProjectIDs: ["project"], query: ""))
        #expect(!RemoteWorktreeReorderPolicy.allows(row, editableProjectIDs: ["other"], query: ""))
        #expect(!RemoteWorktreeReorderPolicy.allows(row, editableProjectIDs: ["project"], query: "feature"))
        let main = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "Project", displayBranch: "main", state: .closed,
            isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: .init(id: "main", projectID: "project"))
        #expect(!RemoteWorktreeReorderPolicy.allows(main, editableProjectIDs: ["project"], query: ""))
    }

    @Test("empty sidebar projection still exposes Add Remote Mac")
    func emptyProjectionShowsAddRemoteMacAction() throws {
        let projection = RemoteMacsSidebarProjection.make(
            savedRemoteMacs: [],
            discoveryCandidates: [],
            selectedRemoteIdentity: nil,
            connectionState: { _ in .offline }
        )

        #expect(projection.title == "Remote Macs")
        #expect(projection.rows.isEmpty)
        #expect(projection.addAction == .addRemoteMac)
        #expect(projection.isVisible)
    }

    @Test("saved remotes produce rows keyed by remote identity")
    func savedRemotesProduceRemoteRows() throws {
        let remote = try makeRemoteMac(label: "Studio Mac")
        let identity = RemoteMacIdentity(remote)

        let projection = RemoteMacsSidebarProjection.make(
            savedRemoteMacs: [remote],
            discoveryCandidates: [],
            selectedRemoteIdentity: identity,
            connectionState: { requested in
                requested == identity ? .connected : .offline
            }
        )

        let row = try #require(projection.rows.first)
        #expect(projection.rows.count == 1)
        #expect(row.id == .remoteMac(identity))
        #expect(row.remoteIdentity == identity)
        #expect(row.title == "Studio Mac")
        #expect(row.isSelected)
        #expect(row.connectionState == .connected)
    }

    @Test("""
    @spec REMOTE-12.7: While a saved Remote Mac is connected, its latest \
    panes-state snapshot shall project remote worktree and pane rows beneath \
    that Mac in the sidebar.
    """)
    func savedRemoteProjectionIncludesWorktreeAndPaneRows() throws {
        let remote = try makeRemoteMac(label: "Studio Mac")
        let identity = RemoteMacIdentity(remote)
        let snapshot = [
            makeWorktreePanes(
                path: "/repo/.worktrees/feature",
                displayName: "feature",
                layout: .split(
                    direction: .horizontal,
                    ratio: 0.5,
                    left: .leaf(
                        sessionName: "graftty-left",
                        title: "editor",
                        attentionText: nil,
                        isBusy: false,
                        attentionSource: nil
                    ),
                    right: .leaf(
                        sessionName: "graftty-right",
                        title: "agent",
                        attentionText: nil,
                        isBusy: false,
                        attentionSource: nil
                    )
                )
            )
        ]

        let projection = RemoteMacsSidebarProjection.make(
            savedRemoteMacs: [remote],
            discoveryCandidates: [],
            worktreePanesByRemote: [identity: snapshot],
            selectedRemoteIdentity: nil,
            selectedRemoteWorktreePath: nil,
            selectedRemotePaneSessionName: nil,
            connectionState: { _ in .connected }
        )

        #expect(projection.rows.map(\.id) == [
            .remoteMac(identity),
            .worktree(identity, "/repo/.worktrees/feature"),
            .pane(identity, "/repo/.worktrees/feature", "graftty-left"),
            .pane(identity, "/repo/.worktrees/feature", "graftty-right"),
        ])
        #expect(projection.rows.map(\.title) == [
            "Studio Mac", "feature", "editor", "agent",
        ])
        #expect(projection.rows.map(\.level) == [.remoteMac, .worktree, .pane, .pane])
    }

    @Test("selected remote pane row is highlighted")
    func selectedRemotePaneRowIsHighlighted() throws {
        let remote = try makeRemoteMac(label: "Studio Mac")
        let identity = RemoteMacIdentity(remote)
        let worktreePath = "/repo/.worktrees/feature"

        let projection = RemoteMacsSidebarProjection.make(
            savedRemoteMacs: [remote],
            discoveryCandidates: [],
            worktreePanesByRemote: [
                identity: [
                    makeWorktreePanes(
                        path: worktreePath,
                        displayName: "feature",
                        layout: .leaf(
                            sessionName: "graftty-agent",
                            title: "agent",
                            attentionText: nil,
                            isBusy: false,
                            attentionSource: nil
                        )
                    )
                ]
            ],
            selectedRemoteIdentity: identity,
            selectedRemoteWorktreePath: worktreePath,
            selectedRemotePaneSessionName: "graftty-agent",
            connectionState: { _ in .connected }
        )

        #expect(projection.rows.first(where: { $0.id == .remoteMac(identity) })?.isSelected == false)
        #expect(projection.rows.first(where: { $0.id == .worktree(identity, worktreePath) })?.isSelected == false)
        #expect(projection.rows.first(where: { $0.id == .pane(identity, worktreePath, "graftty-agent") })?
            .isSelected == true)
    }

    @Test("stale selected remote pane falls back to remote worktree selection")
    func staleSelectedRemotePaneFallsBackToWorktreeSelection() throws {
        let identity = RemoteMacIdentity(try makeRemoteMac())
        var state = RemoteMacSidebarSelectionState(
            selectedWorktreePath: nil,
            selectedRemoteIdentity: identity,
            selectedRemoteWorktreePath: "/repo/.worktrees/feature",
            selectedRemotePaneSessionName: "stale-session"
        )
        let snapshot = [
            makeWorktreePanes(
                path: "/repo/.worktrees/feature",
                displayName: "feature",
                layout: .leaf(
                    sessionName: "live-session",
                    title: "shell",
                    attentionText: nil,
                    isBusy: false,
                    attentionSource: nil
                )
            )
        ]

        RemoteMacSidebarSelectionReducer.reconcileRemoteSelection(
            worktreePanesByRemote: [identity: snapshot],
            state: &state
        )

        #expect(state.selectedRemoteIdentity == identity)
        #expect(state.selectedRemoteWorktreePath == "/repo/.worktrees/feature")
        #expect(state.selectedRemotePaneSessionName == nil)
    }

    @Test("discovered candidates do not appear in sidebar until saved")
    func discoveredCandidatesStayOutOfSidebarProjection() throws {
        let candidate = try makeCandidate(label: "Unsaved Mac")

        let projection = RemoteMacsSidebarProjection.make(
            savedRemoteMacs: [],
            discoveryCandidates: [candidate],
            selectedRemoteIdentity: nil,
            connectionState: { _ in .discovered }
        )

        #expect(projection.rows.isEmpty)
        #expect(projection.addAction == .addRemoteMac)
    }

    @Test("add sheet lifecycle starts and stops discovery through model seam")
    func addSheetLifecycleStartsAndStopsDiscovery() throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = RemoteMacsModel(store: store)
        let browser = FakeDiscoveryBrowser()
        model.setDiscoveryBrowser(browser)
        let lifecycle = AddRemoteMacSheetLifecycle(
            startDiscovery: { model.startDiscovery() },
            stopDiscovery: { model.stopDiscovery() }
        )

        lifecycle.appear()
        lifecycle.disappear()

        #expect(browser.startCount == 1)
        #expect(browser.stopCount == 1)
    }

    @Test("manual URL validation accepts http or https with host")
    func manualURLValidationAcceptsHTTPWithHost() {
        let http = AddRemoteMacFormController.validateManualURL("http://studio.local:9443")
        let https = AddRemoteMacFormController.validateManualURL("https://studio.example")

        #expect((try? http.get()) == URL(string: "http://studio.local:9443"))
        #expect((try? https.get()) == URL(string: "https://studio.example"))
    }

    @Test("manual URL validation rejects empty invalid and loopback URLs")
    func manualURLValidationRejectsBadInput() {
        #expect(AddRemoteMacFormController.validateManualURL("").isFailure)
        #expect(AddRemoteMacFormController.validateManualURL("not a url").isFailure)
        #expect(AddRemoteMacFormController.validateManualURL("ftp://studio.local").isFailure)
        #expect(AddRemoteMacFormController.validateManualURL("http://localhost:9443").isFailure)
        #expect(AddRemoteMacFormController.validateManualURL("http://127.0.0.1:9443").isFailure)
        #expect(AddRemoteMacFormController.validateManualURL("http://[::1]:9443").isFailure)
    }

    @Test("selecting remote keeps selection distinct from local worktree")
    func selectingRemoteClearsLocalSelection() throws {
        var state = RemoteMacSidebarSelectionState(
            selectedWorktreePath: "/repo/main",
            selectedRemoteIdentity: nil,
            selectedRemoteWorktreePath: nil,
            selectedRemotePaneSessionName: nil
        )
        let identity = RemoteMacIdentity(try makeRemoteMac())

        RemoteMacSidebarSelectionReducer.selectRemote(identity, state: &state)

        #expect(state.selectedWorktreePath == nil)
        #expect(state.selectedRemoteIdentity == identity)
        #expect(state.selectedRemoteWorktreePath == nil)
        #expect(state.selectedRemotePaneSessionName == nil)

        RemoteMacSidebarSelectionReducer.selectLocalWorktree("/repo/main", state: &state)

        #expect(state.selectedWorktreePath == "/repo/main")
        #expect(state.selectedRemoteIdentity == nil)
        #expect(state.selectedRemoteWorktreePath == nil)
        #expect(state.selectedRemotePaneSessionName == nil)
    }

    @Test("selecting remote pane clears local worktree selection")
    func selectingRemotePaneClearsLocalSelection() throws {
        var state = RemoteMacSidebarSelectionState(
            selectedWorktreePath: "/repo/main",
            selectedRemoteIdentity: nil,
            selectedRemoteWorktreePath: nil,
            selectedRemotePaneSessionName: nil
        )
        let identity = RemoteMacIdentity(try makeRemoteMac())

        RemoteMacSidebarSelectionReducer.selectRemotePane(
            identity,
            worktreePath: "/repo/.worktrees/feature",
            sessionName: "graftty-agent",
            state: &state
        )

        #expect(state.selectedWorktreePath == nil)
        #expect(state.selectedRemoteIdentity == identity)
        #expect(state.selectedRemoteWorktreePath == "/repo/.worktrees/feature")
        #expect(state.selectedRemotePaneSessionName == "graftty-agent")
    }

    @Test("candidate selection in add sheet does not imply pairing success")
    func selectingCandidateDoesNotCompletePairing() throws {
        var controller = AddRemoteMacFormController()
        let candidate = try makeCandidate()

        controller.selectCandidate(candidate)

        #expect(controller.selectedCandidateIdentity == RemoteMacIdentity(candidate))
        #expect(controller.selectedPairingBaseURL == candidate.baseURL)
        #expect(controller.phase == .candidateSelected(RemoteMacIdentity(candidate)))
        #expect(!controller.canConfirmVerification)

        let code = RemoteVerificationCode(digits: "123456")
        controller.showVerificationCode(code)
        #expect(controller.phase == .verifying(code))
        #expect(controller.canConfirmVerification)
    }

    @Test("cancelling driver after begin prevents introduce")
    func cancellingDriverAfterBeginPreventsIntroduce() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let payload = PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "studio-mac"),
            hostKind: .mac,
            hostDisplayName: "Studio Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: hostPublicKey),
            nonce: RemotePairingNonce.generate(),
            expiry: Date().addingTimeInterval(300),
            pairingURL: URL(string: "http://studio.local:9443/v2/pairing")!
        )
        let transport = CancellablePairingTransport(
            payload: payload,
            hostPublicKey: hostPublicKey
        )
        let driver = LocalAddRemoteMacPairingDriver(
            identityStore: ClientIdentityStore(directory: dir),
            pinnedHostStore: PinnedHostStore(directory: dir),
            clientDeviceID: RemoteDeviceID(value: "client-mac"),
            clientKind: .mac,
            clientDisplayName: "Client Mac",
            transport: await transport.makeTransport()
        )

        let task = Task {
            try await driver.beginPairing(baseURL: URL(string: "http://studio.local:9443")!)
        }
        await transport.waitUntilBeginRequested()
        task.cancel()
        await transport.releaseBegin()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let paths = await transport.recordedPaths
        #expect(paths == ["/v2/pairing/begin"])
    }

    private func makeRemoteMac(
        id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0x22,
        baseURL: URL? = URL(string: "http://studio.local:9443")
    ) throws -> RemoteMac {
        RemoteMac(
            id: id,
            label: label,
            fingerprint: try fingerprint(fingerprintByte),
            lastKnownBaseURL: baseURL,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeCandidate(
        id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0x22,
        baseURL: URL = URL(string: "http://studio.local:9443")!
    ) throws -> GrafttyBonjourCandidate {
        GrafttyBonjourCandidate(
            deviceID: id,
            label: label,
            fingerprint: try fingerprint(fingerprintByte),
            baseURL: baseURL,
            protocolVersion: GrafttyBonjourService.discoveryVersion,
            pairingStatus: .required,
            discoveredAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private func makeWorktreePanes(
        path: String,
        displayName: String,
        layout: PaneLayoutNode?
    ) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: displayName,
            repoDisplayName: "graftty",
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout
        )
    }

    private func fingerprint(_ byte: UInt8) throws -> RemoteIdentityFingerprint {
        try RemoteIdentityFingerprint(rawBytes: Data(repeating: byte, count: 32))
    }

    private func tempStoreURL() throws -> URL {
        let dir = try tempDirectory()
        return dir.appendingPathComponent("remote-macs.json")
    }

    private func tempDirectory() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

 extension Result {
    fileprivate
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private final class FakeDiscoveryBrowser: RemoteMacDiscoveryBrowsing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private actor CancellablePairingTransport {
    private let payload: PairingPayload
    private let hostPublicKey: RemoteIdentityPublicKey
    private var beginContinuation: CheckedContinuation<Void, Never>?
    private var beginObservedContinuation: CheckedContinuation<Void, Never>?
    private(set) var recordedPaths: [String] = []

    init(payload: PairingPayload, hostPublicKey: RemoteIdentityPublicKey) {
        self.payload = payload
        self.hostPublicKey = hostPublicKey
    }

    func makeTransport() -> LocalPairingClient.Transport {
        { [self] request in
            try await self.handle(request)
        }
    }

    func waitUntilBeginRequested() async {
        if recordedPaths.contains("/v2/pairing/begin") { return }
        await withCheckedContinuation { continuation in
            beginObservedContinuation = continuation
        }
    }

    func releaseBegin() {
        beginContinuation?.resume()
        beginContinuation = nil
    }

    private func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        recordedPaths.append(path)

        let body: Data
        if path.hasSuffix("/begin") {
            beginObservedContinuation?.resume()
            beginObservedContinuation = nil
            await withCheckedContinuation { continuation in
                beginContinuation = continuation
            }
            body = try JSONEncoder.iso8601().encode(payload)
        } else if path.hasSuffix("/introduce") {
            body = try JSONEncoder.iso8601().encode(
                PairingIntroduceResponse(
                    hostPublicKey: hostPublicKey,
                    expiry: payload.expiry
                )
            )
        } else {
            throw URLError(.unsupportedURL)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

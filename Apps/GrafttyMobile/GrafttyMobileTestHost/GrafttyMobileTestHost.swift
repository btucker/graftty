import SwiftUI
#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import GrafttyProtocol
import GrafttyCommandUI
import UIKit
import GrafttyRemoteClient
import Observation
import GhosttyTerminal
@testable import GrafttyMobileKit
#endif

// UIKit and WebKit integration tests need UIApplicationMain and foreground
// events, without starting production pairing, session, or biometric state.
@main
struct GrafttyMobileTestHost: App {
    init() {
        #if GRAFTTY_BROWSER_CONTROL_FIXTURE
        if Self.agentIntegrationEndpoint != nil { NotificationActivationFixture.installRestoredIfNeeded() }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            #if GRAFTTY_BROWSER_CONTROL_FIXTURE
            if let endpoint = Self.agentIntegrationEndpoint {
                AgentIntegrationFixture(endpoint: endpoint).ignoresSafeArea()
            } else if ProcessInfo.processInfo.arguments.contains("--recent-panes-fixture") {
                RecentPaneFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--context-fixture") {
                WorktreeContextFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--scrollback-fixture") {
                ScrollbackFixture().ignoresSafeArea(.keyboard)
            } else if ProcessInfo.processInfo.arguments.contains("--image-controls-fixture") {
                ImageControlsFixture()
            } else {
                BrowserControlFixture()
            }
            #else
            Color.clear
            #endif
        }
    }

    #if GRAFTTY_BROWSER_CONTROL_FIXTURE
    private static var agentIntegrationEndpoint: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--agent-integration-url"),
              arguments.indices.contains(index + 1) else {
            if arguments.contains(where: ["--recent-panes-fixture", "--context-fixture", "--scrollback-fixture",
                "--image-controls-fixture", "--browser-control-fixture"].contains) { return nil }
            // A notification launches the executable through Springboard,
            // which does not retain XCUIApplication's launch arguments.
            return NotificationActivationFixture.restoredEndpoint
        }
        return URL(string: arguments[index + 1])
    }
    #endif
}

#if GRAFTTY_BROWSER_CONTROL_FIXTURE
private struct WorktreeContextFixture: View {
    @State private var mounts = 0
    @State private var coordinator = RemoteConnectionCoordinator()
    private let row: WorktreePanes = {
        let start = Date().addingTimeInterval(-3600)
        let recap = AttentionRecap(title: "Worktree context", context: "Help me reload my context when returning to a worktree.",
            completed: "Built a current brief with expandable history.", next: "Try it on a phone.",
            checkpoint: "Chose the brief with expandable history", decisions: ["Keep the purpose title stable."])
        var brief = WorktreeBrief(recap: recap, at: start.addingTimeInterval(60))
        for index in 1...9 {
            brief.update(.init(title: "Worktree context", completed: "Agent progress \(index)", next: "Review the timeline.",
                checkpoint: "Timeline checkpoint \(index)"), at: start.addingTimeInterval(Double(index + 1) * 60))
        }
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        history.record(.init(text: "Keep my decisions visible.", at: start.addingTimeInterval(270)))
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: recap)
        return .init(path: "/task", displayName: "rethink-notifications", repoDisplayName: "graftty", displayBranch: "task",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "task", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop,
                brief: brief, history: history))
    }()
    var body: some View {
        ScrollbackFixture()
            .onAppear { mounts += 1 }
            .overlay(alignment: .topTrailing) {
                RemoteOpenButton(host: Host(label: "Fixture", baseURL: URL(string: "https://fixture.invalid")!),
                    worktree: row.path, coordinator: coordinator, sessionName: "fixture",
                    ownerDeviceID: .init(value: "fixture-phone"), isActive: true,
                    managementTransport: { _, _ in .openResource(.offers([])) },
                    browserConnectionReady: true, isPaneFocused: true, hasOwnershipSnapshot: true,
                    isPaneOwner: { true }, canPresentAuthentication: { true }, terminalRequest: .constant(nil))
                    .padding(12)
            }
            .overlay(alignment: .bottom) {
                Text("Terminal mounts: \(mounts)")
                    .accessibilityIdentifier("Context terminal mounts")
            }
            .modifier(MobileWorktreeContextDrawer(context: SidebarWorktreeContext(worktree: row)))
            .environment(\.colorScheme, .dark)
    }
}

/// Uses the production terminal container and recognizers with deterministic
/// output. No pairing or network timing is involved in these gesture probes.
private struct ScrollbackFixture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ScrollbackFixtureController { .init() }
    func updateUIViewController(_ controller: ScrollbackFixtureController, context: Context) {}
}

private final class ScrollbackFixtureController: UIViewController {
    let container = TerminalInputContainerView()
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    let status = UILabel()
    var timer: Timer?
    var nextRow = 0
    var follower = ProcessInfo.processInfo.arguments.contains("--follower")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14\nscrollback-limit = 10000000")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        // Fullscreen panes install this recognizer even when the test does not
        // navigate back, so exercise its competition with vertical drags.
        container.onBackRequested = {}
        container.accessibilityIdentifier = "Scrollback terminal"
        view.addSubview(container)
        status.accessibilityIdentifier = "Scrollback status"
        status.textColor = .white
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.numberOfLines = 3
        view.addSubview(status)
        let controls = UIStackView()
        controls.axis = .horizontal
        controls.distribution = .fillEqually
        for (title, action) in [("Append", #selector(appendOutput)), ("Stream", #selector(streamOutput)), ("Switch owner", #selector(switchOwner)), ("Top", #selector(top)), ("Bottom", #selector(bottom))] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.addTarget(self, action: action, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        controls.tag = 123
        view.addSubview(controls)
        Task { @MainActor in
            self.view.layoutIfNeeded()
            if self.follower {
                let renderer = MobilePagedTerminalRenderer(session: self.session) { cols, rows in
                    self.container.authoritativeGrid = .init(cols: cols, rows: rows)
                    self.container.layoutIfNeeded()
                }
                try await renderer.resize(cols: 80, rows: 24)
                self.container.snapshotScrollView.showsAdditionalHistory = true
            }
            self.appendRows(500)
            try await MobilePagedTerminalRenderer(session: self.session, prepareGrid: { _, _ in }).flushOutput()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatus() }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        status.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 50)
        view.viewWithTag(123)?.frame = CGRect(x: area.minX, y: status.frame.maxY, width: area.width, height: 44)
        container.frame = CGRect(x: area.minX, y: status.frame.maxY + 44, width: area.width, height: max(1, area.height - 94))
    }

    func appendRows(_ count: Int) {
        let lines = (nextRow..<(nextRow + count)).map { String(format: "ROW-%06d", $0) }
        nextRow += count
        session.receive(lines.joined(separator: "\r\n") + "\r\n")
    }
    @objc func appendOutput() { appendRows(50) }
    @objc func streamOutput() {
        Task { @MainActor in
            for _ in 0..<150 {
                self.appendRows(1)
                try await Task.sleep(for: .milliseconds(30))
            }
        }
    }
    @objc func bottom() { _ = container.terminalView.surface?.performAction("scroll_to_bottom") }
    @objc func top() { _ = container.terminalView.surface?.scrollToRow(5) }
    @objc func switchOwner() {
        follower.toggle()
        container.authoritativeGrid = follower ? .init(cols: 80, rows: 24) : nil
        container.snapshotScrollView.showsAdditionalHistory = follower
        container.layoutIfNeeded()
    }
    func updateStatus() {
        guard let bar = container.snapshotScrollView.scrollbar else { return }
        let first = session.readViewportText()?.split(separator: "\n").first.map(String.init) ?? ""
        let scroll = container.snapshotScrollView
        let firstFrame = scroll.additionalHistoryFrameForTesting ?? container.terminalView.frame
        let gap = max(0, firstFrame.minY - scroll.contentOffset.y)
        let value = "\(follower ? "follower" : "leader") offset=\(bar.offset) total=\(bar.total) len=\(bar.len) gap=\(Int(gap)) width=\(Int(container.bounds.width)) height=\(Int(container.bounds.height)) first=\(first)"
        status.text = value
        status.accessibilityValue = value
    }
    deinit { timer?.invalidate() }
}

private struct BrowserControlFixture: View {
    @State private var activated = false
    var body: some View {
        VStack(spacing: 24) {
            RemoteOpenButton.floatingControl(availableCount: 1, isBusy: false) { activated = true }
                .padding(14)
            Text(activated ? "Activated" : "Idle")
        }
        .preferredColorScheme(.light)
    }
}

/// Launch-only interaction fixture for the production clipped-pane controls.
private struct ImageControlsFixture: View {
    private var wide: Bool { ProcessInfo.processInfo.arguments.contains("--wide-controls") }
    @State private var coordinator = RemoteConnectionCoordinator(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        connectionsAllowedInitially: false)
    @State private var host = Host(label: "Fixture Mac", baseURL: URL(string: "https://host.invalid")!)
    @State private var offer: RemoteOpenOffer?
    private let device = RemoteDeviceID(value: "fixture-phone")
    private var bytes: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }

    var body: some View {
        if wide {
            VStack(spacing: 0) { pane; Spacer(minLength: 0) }
                .frame(maxWidth: .infinity).background(.black)
                .preferredColorScheme(.dark)
        } else { pane }
    }

    private var pane: some View {
        Color.black.frame(width: wide ? 360 : 78, height: wide ? 520 : 78)
            .overlay(alignment: .topLeading) {
                if wide {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("~/projects/graftty").foregroundStyle(.secondary)
                        Text("$ swift test").foregroundStyle(.green)
                        Text("Build complete.")
                        Text("All tests passed.").foregroundStyle(.green)
                    }
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white).padding(.top, 100).padding(.leading, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if wide {
                    TerminalFloatingGlyphButton(systemName: "chevron.left", accessibilityLabel: "Back", action: {})
                        .modifier(TerminalFloatingControlPlacement())
                }
            }
            .overlay(alignment: .topTrailing) {
                RemoteOpenButton(host: host, worktree: "/fixture", coordinator: coordinator, sessionName: "pane",
                    ownerDeviceID: device, isActive: true, managementTransport: { request, _ in
                        if case .openResource(_, .read) = request { return .openResource(.chunk(bytes)) }
                        return .openResource(.offers(offer.map { [$0] } ?? []))
                    }, browserConnectionReady: true, isPaneFocused: true, hasOwnershipSnapshot: true,
                    isPaneOwner: { true }, canPresentAuthentication: { true }, terminalRequest: .constant(nil))
                    .modifier(TerminalFloatingControlPlacement()).padding(.trailing, 12)
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Image pane")
            .accessibilityIdentifier("Image pane")
            .preferredColorScheme(wide ? .dark : .light)
            .onAppear {
                guard offer == nil else { return }
                offer = RemoteOpenOffer(id: UUID(), filename: "image.png", byteCount: bytes.count,
                    paneSessionName: "pane", previewKind: "image", previewOwnerDeviceID: device)
            }
    }
}


/// Uses real mobile Back chrome, target resolution, SessionStep routing, and
/// terminal views. Only the remote snapshot and byte stream are deterministic.
@MainActor
private struct RecentPaneFixture: View {
    @State private var model = RecentPaneFixtureModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack(path: $model.path) {
            picker
                .navigationDestination(for: Host.self) { _ in picker }
                .navigationDestination(for: ProjectStep.self) { _ in picker }
                .navigationDestination(for: SessionStep.self) { step in
                    let key = step.host.id.uuidString + step.sessionName
                    SingleSessionView(step: step, navigationPath: $model.path,
                        isFullScreen: sizeClass != .regular, showsProjectRail: false,
                        isEmbeddedPane: sizeClass == .regular,
                        onBackToWorktrees: {
                            RootView.applyCompactBack(step: step, appState: model.state,
                                navigationPath: &model.path, showsProjectRail: false)
                        }, retainedPanes: model.pool, attentionWorktrees: model.rows,
                        initialClient: model.clients[key], initialController: model.controllers[key])
                        .overlay(alignment: .bottom) {
                            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                Text("\(step.host.label) | \(step.worktreePath ?? "") | \(step.sessionName) | "
                                    + (model.clients[key]?.session.readViewportText() ?? ""))
                                    .font(.caption2).accessibilityIdentifier("Recent pane rendered target")
                            }.allowsHitTesting(false)
                        }
                }
        }
        .environment(\.recentPaneActions, .init(history: model.state.recentPanes, open: { entry in
            Task { await model.open(entry) }
        }))
        // Prevent unrelated live dialing in this deterministic fixture.
        .environment(\.scenePhase, .inactive)
        .alert("Could not open pane", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var picker: some View {
        List {
            ForEach(model.rows, id: \.path) { row in
                Button("Open \(row.displayName)") { model.select(row) }
            }
        }.navigationTitle("Recent pane worktrees")
    }
}

@MainActor @Observable
private final class RecentPaneFixtureModel {
    let host = Host(label: "Studio", baseURL: URL(string: "https://fixture.invalid")!)
    let state = IPadAppState(defaults: UserDefaults(suiteName: "recent-pane-fixture-\(UUID())")!)
    var path = NavigationPath()
    var error: String?
    var clients: [String: SessionClient] = [:]
    var controllers: [String: TerminalController] = [:]
    var rows: [WorktreePanes] = []
    let pool = RetainedPaneClientPool<RetainedMobilePane>()
    var generation = 0

    init() {
        for name in ["alpha", "beta", "removed"] {
            let route = "pane-\(name)"
            let leaf = PaneLayoutNode.leaf(sessionName: route, title: "Terminal \(name)", attentionText: nil, isBusy: false, attentionSource: nil)
            let layout: PaneLayoutNode = name == "beta" ? .split(direction: .horizontal, ratio: 0.5,
                left: .leaf(sessionName: "pane-decoy", title: "Decoy", attentionText: nil, isBusy: false, attentionSource: nil), right: leaf) : leaf
            let paneIDs = Dictionary(uniqueKeysWithValues: layout.leaves.map { ($0.sessionName, "slot-" + $0.sessionName) })
            let row = WorktreePanes(path: "/repo/\(name)", displayName: name, repoDisplayName: "Project", displayBranch: name,
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                layout: layout, sidebar: .init(id: name, projectID: "project", paneIDs: paneIDs, paneSlotIDs: Array(paneIDs.values)))
            state.recentPanes.record(hostID: host.id, hostLabel: host.label, worktree: row, sessionName: route)
            guard name != "removed" else { continue }
            rows.append(row)
            for pane in layout.leaves {
                let client = SessionClient(sessionName: pane.sessionName, webSocketFactory: { RecentPaneFixtureSocket() })
                _ = pool.acquire(.init(hostID: host.id, sessionName: pane.sessionName)) { RetainedMobilePane(client: client) }
                client.start()
                client.session.receive(Data("VISIBLE_\(pane.sessionName.replacingOccurrences(of: "pane-", with: "").uppercased())\r\n".utf8))
                clients[host.id.uuidString + pane.sessionName] = client
                controllers[host.id.uuidString + pane.sessionName] = MobileTerminalControllerFactory.make(configText: "font-size = 14")
            }
        }
    }

    func select(_ row: WorktreePanes) {
        generation += 1
        guard let pane = row.layout?.leaves.first else { return }
        select(.init(rows: rows, worktree: row, pane: pane))
    }

    private func select(_ target: MobileNotificationActivation.Target) {
        RootView.applyRecentPaneTarget(target, host: host, to: state)
        state.recentPanes.record(hostID: host.id, hostLabel: host.label, worktree: target.worktree, sessionName: target.pane.sessionName)
        path = RootView.compactSelection(appState: state, hosts: [host], showsProjectRail: false)!.path
    }

    func open(_ entry: MobileRecentPanes.Entry) async {
        generation += 1
        let captured = generation
        let oldPath = path
        do {
            let target = try await MobileRecentPanes.resolve(entry, fetch: { self.rows }, reopen: { _ in },
                isCurrent: { self.generation == captured && self.path == oldPath })
            select(target)
        } catch { state.recentPanes.forget(entry); self.error = "This pane is no longer available." }
    }
}

private final class RecentPaneFixtureSocket: WebSocketClient, @unchecked Sendable {
    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func close() {}
}

#endif

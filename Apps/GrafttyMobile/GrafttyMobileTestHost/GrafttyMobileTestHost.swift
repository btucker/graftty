import SwiftUI
#if GRAFTTY_BROWSER_CONTROL_FIXTURE
import GrafttyProtocol
import GrafttyCommandUI
import UIKit
import GhosttyTerminal
@testable import GrafttyMobileKit
#endif

// UIKit and WebKit integration tests need UIApplicationMain and foreground
// events, without starting production pairing, session, or biometric state.
@main
struct GrafttyMobileTestHost: App {
    var body: some Scene {
        WindowGroup {
            #if GRAFTTY_BROWSER_CONTROL_FIXTURE
            if let endpoint = Self.agentIntegrationEndpoint {
                AgentIntegrationFixture(endpoint: endpoint).ignoresSafeArea()
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
              arguments.indices.contains(index + 1) else { return nil }
        return URL(string: arguments[index + 1])
    }
    #endif
}

#if GRAFTTY_BROWSER_CONTROL_FIXTURE
private struct WorktreeContextFixture: View {
    @State private var mounts = 0
    private let row: WorktreePanes = {
        let recap = AttentionRecap(title: "Worktree context", context: "Help me reload my context when returning to a worktree.",
            completed: "Built a current brief with expandable history.", next: "Try it on a phone.",
            checkpoint: "Chose the brief with expandable history", decisions: ["Keep the purpose title stable."])
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: recap)
        return .init(path: "/task", displayName: "rethink-notifications", repoDisplayName: "graftty", displayBranch: "task",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "task", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop,
                brief: WorktreeBrief(recap: recap, at: .now)))
    }()
    var body: some View {
        ScrollbackFixture()
            .onAppear { mounts += 1 }
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

#endif

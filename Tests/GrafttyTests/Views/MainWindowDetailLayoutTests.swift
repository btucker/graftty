import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
@Suite("Main window detail layout")
struct MainWindowDetailLayoutTests {
    @Test("@spec CONTEXT-55: While Context is open on desktop, the application shall reserve its width alongside the terminal below the breadcrumb, shrink the terminal when it opens, and restore that width when it closes without overlaying terminal content.")
    func contextReservesTerminalWidth() async throws {
        let terminalProbe = NSView(), inspectorProbe = NSView()
        func layout(open: Bool) -> some View {
            MainWindowDetailLayout {
                Color.gray.frame(height: 30)
            } content: {
                Color.black.ignoresSafeArea()
                    .background(FrameProbe(view: terminalProbe))
            } inspector: {
                if open {
                    Color.gray.frame(width: 360)
                        .background(FrameProbe(view: inspectorProbe))
                }
            }
        }
        let host = NSHostingView(rootView: layout(open: false))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for open in [false, true, false] {
            host.rootView = layout(open: open)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let terminal = terminalProbe.convert(terminalProbe.bounds, to: host)
            #expect(abs(terminal.width - (open ? 640 : 1000)) < 1)
            if open {
                let inspector = inspectorProbe.convert(inspectorProbe.bounds, to: host)
                #expect(terminal.maxX <= inspector.minX)
                #expect(abs(inspector.maxX - host.bounds.maxX) < 1)
                #expect(inspector.minY >= 30)
                #expect(abs(inspector.height - 670) < 1)
            }
        }
    }

    enum ContentState: CaseIterable, Sendable {
        case noSelection, noTerminal, remoteUnavailable, terminal, workspace
    }

    @Test("@spec LAYOUT-1.12: While the macOS window detail is visible, the application shall keep its breadcrumb header at the top and reserve the remaining height for content, including when no terminal pane is open and after resizing.",
          arguments: ContentState.allCases, [false, true])
    func headerStaysAtTop(state: ContentState, sidebarHidden: Bool) async throws {
        _ = NSApplication.shared
        let headerProbe = NSView()
        let contentProbe = NSView()
        let manager = TerminalManager(socketPath: "/tmp/detail-layout-test-unused.sock")
        let layout = MainWindowDetailLayout {
            BreadcrumbBar(repoName: "graftty", worktreeDisplayName: "agent-workspace", worktreeEmoji: nil,
                worktreePath: nil, branchName: nil, isHomeCheckout: false,
                prInfo: nil, theme: .fallback, sidebarHidden: sidebarHidden,
                canGoBack: false, canGoForward: false, historyItems: [], currentTarget: nil,
                onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in }, onRefreshPR: {})
                .background(FrameProbe(view: headerProbe))
        } content: {
            content(state: state, manager: manager)
                .background(FrameProbe(view: contentProbe))
        }
        let hosting = NSHostingView(rootView: layout)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }

        for height in [600.0, 800.0] {
            window.setContentSize(NSSize(width: 900, height: height))
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            #expect(abs(hosting.bounds.height - height) < 1)
            let header = headerProbe.convert(headerProbe.bounds, to: hosting)
            let content = contentProbe.convert(contentProbe.bounds, to: hosting)
            #expect(abs(header.minY - hosting.bounds.minY) < 1)
            #expect(header.height > 0 && header.height <= 44)
            #expect(content.minY >= header.maxY - 1)
            #expect(abs(content.midY - (header.maxY + hosting.bounds.maxY) / 2) < 1)
        }
    }

    @Test("@spec LAYOUT-1.13: While agent tabs are visible, the application shall keep Back, Forward, the repository/worktree breadcrumb, and Context visible and clickable in the window header above the tabs.", arguments: [false, true])
    func workspaceKeepsWindowNavigation(sidebarHidden: Bool) async throws {
        _ = NSApplication.shared
        let headerProbe = NSView(), contentProbe = NSView()
        var backClicks = 0, forwardClicks = 0, contextClicks = 0
        let manager = TerminalManager(socketPath: "/tmp/workspace-navigation-test-unused.sock")
        let root = NavigationSplitView(columnVisibility: .constant(sidebarHidden ? .detailOnly : .all)) {
            Text("Worktrees").frame(minWidth: 220)
        } detail: {
            MainWindowDetailLayout {
                BreadcrumbBar(repoName: "graftty", worktreeDisplayName: "agent-workspace", worktreeEmoji: nil,
                    worktreePath: "/repo/agent-workspace", branchName: "agent-workspace", isHomeCheckout: false,
                    prInfo: nil, theme: .fallback, sidebarHidden: sidebarHidden,
                    canGoBack: true, canGoForward: true,
                    historyItems: [.init(target: .local("/repo/agent-workspace"), repoName: "graftty",
                        worktreeName: "agent-workspace", branchName: "agent-workspace", remoteMacName: nil)],
                    currentTarget: .local("/repo/agent-workspace"),
                    onGoBack: { backClicks += 1 }, onGoForward: { forwardClicks += 1 },
                    onSelectHistory: { _ in }, onRefreshPR: {}, onToggleContext: { contextClicks += 1 })
                    .background(FrameProbe(view: headerProbe))
            } content: {
                content(state: .workspace, manager: manager)
                    .background(FrameProbe(view: contentProbe))
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let header = headerProbe.convert(headerProbe.bounds, to: hosting)
        let workspace = contentProbe.convert(contentProbe.bounds, to: hosting)
        #expect(header.height >= 30)
        #expect(header.minY >= hosting.bounds.minY - 1)
        #expect(workspace.minY >= header.maxY - 1)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        var visibleHeaderPixels = 0
        for x in Int(header.minX * scale)..<min(bitmap.pixelsWide, Int(header.maxX * scale)) {
            for y in max(0, Int(header.minY * scale))..<min(bitmap.pixelsHigh, Int(header.maxY * scale)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.5 && color.greenComponent > 0.5 && color.blueComponent > 0.5 {
                    visibleHeaderPixels += 1
                }
            }
        }
        #expect(visibleHeaderPixels > 50, "Navigation must be drawn, not merely assigned a frame beneath the titlebar")
        for x in [header.minX + (sidebarHidden ? 156 : 12) + 12,
                  header.minX + (sidebarHidden ? 156 : 12) + 38, header.maxX - 40] {
            let location = hosting.convert(NSPoint(x: x, y: header.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(backClicks == 1)
        #expect(forwardClicks == 1)
        #expect(contextClicks == 1)
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("workspace-navigation-\(sidebarHidden ? "collapsed" : "expanded").png"))
        }
    }

    @ViewBuilder
    private func content(state: ContentState, manager: TerminalManager) -> some View {
        switch state {
        case .noSelection:
            ContentUnavailableView("No Worktree Selected", systemImage: "terminal",
                description: Text("Select a worktree from the sidebar or add a repository."))
        case .noTerminal:
            TerminalContentView(terminalManager: manager, splitTree: .constant(SplitTree(root: nil)),
                focusedPaneSlotID: nil, theme: .fallback, onFocusTerminal: { _ in })
        case .remoteUnavailable:
            ContentUnavailableView("Remote Mac", systemImage: "laptopcomputer.and.arrow.down",
                description: Text("Remote Mac selected."))
        case .terminal:
            Color.black
        case .workspace:
            let slot = PaneSlotID(), second = PaneSlotID()
            let worktree: WorktreeEntry = {
                var entry = WorktreeEntry(path: "/repo/agent-workspace", branch: "agent-workspace",
                    state: .running, splitTree: SplitTree(root: .leaf(slot)).inserting(second, at: slot, direction: .horizontal))
                var codex = ManagedAgent(name: "Implement workspace", provider: .codex, parent: nil)
                codex.paneSlotID = slot
                var claude = ManagedAgent(name: "Review lifecycle", provider: .claude, parent: nil)
                claude.paneSlotID = second
                entry.agents = [codex, claude]
                var layout = WorkspaceLayout<PaneSlotID>()
                layout.addAgent(slot); layout.addAgent(second); layout.select(slot)
                entry.workspaceLayout = layout
                return entry
            }()
            WorkspaceContentView(terminalManager: manager, worktree: .constant(worktree),
                onFocusTerminal: { _ in }, onNewTerminal: {}, onCloseTerminal: { _ in })
        }
    }

    @Test("@spec LAYOUT-2.195: While a workspace shows agent tabs, the application shall draw each tab row flush with its pane's leading edge and inset only leading-edge pane content from the sidebar divider.")
    func tabRowsStayFlushWhileLeadingContentIsInset() async throws {
        let left = PaneSlotID(), right = PaneSlotID()
        var probes: [String: NSView] = [:]
        for key in ["leftHeader", "leftContent", "rightHeader", "rightContent"] { probes[key] = NSView() }
        let view = TerminalContentView(terminalManager: TerminalManager(socketPath: "/tmp/graftty-flush-tabs-test.sock"),
            splitTree: .constant(SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(left), right: .leaf(right))))),
            focusedPaneSlotID: left, theme: .fallback, onFocusTerminal: { _ in },
            paneHeader: { id in AnyView(Color.clear.frame(height: 30).background(FrameProbe(view: probes[id == left ? "leftHeader" : "rightHeader"]!))) },
            paneContent: { id in AnyView(Color.clear.background(FrameProbe(view: probes[id == left ? "leftContent" : "rightContent"]!))) },
            leadingContentInset: 6)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        func frame(_ key: String) -> NSRect { probes[key]!.convert(probes[key]!.bounds, to: host) }
        #expect(abs(frame("leftHeader").minX) < 1, "left tab row is inset: \(frame("leftHeader"))")
        #expect(abs(frame("leftContent").minX - 6) < 1, "left content lost its inset: \(frame("leftContent"))")
        #expect(abs(frame("rightContent").minX - frame("rightHeader").minX) < 1,
                "right pane content is inset: \(frame("rightContent")) vs \(frame("rightHeader"))")
    }

    private struct FrameProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

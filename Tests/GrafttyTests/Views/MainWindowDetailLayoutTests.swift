import AppKit
import SwiftUI
import Testing
import GrafttyKit
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
        case noSelection, noTerminal, remoteUnavailable, terminal
    }

    @Test("@spec LAYOUT-1.12: While the macOS window detail is visible, the application shall keep its breadcrumb header at the top and reserve the remaining height for content, including when no terminal pane is open and after resizing.",
          arguments: ContentState.allCases, [false, true])
    func headerStaysAtTop(state: ContentState, sidebarHidden: Bool) async throws {
        _ = NSApplication.shared
        let headerProbe = NSView()
        let contentProbe = NSView()
        let manager = TerminalManager(socketPath: "/tmp/detail-layout-test-unused.sock")
        let layout = MainWindowDetailLayout {
            BreadcrumbBar(repoName: nil, worktreeDisplayName: nil, worktreeEmoji: nil,
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
        }
    }

    private struct FrameProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

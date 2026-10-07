import AppKit
import SwiftUI
import GrafttyCommandUI

@MainActor
final class SidebarReportController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var activeID: String?
    private weak var anchor: SidebarReportButtonView?
    private(set) var popover: NSPopover?
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    func show(_ view: SidebarReportButtonView) {
        if anchor === view, popover?.isShown == true { close(); return }
        close()
        guard let context = view.context, view.window != nil,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return }
        anchor = view
        activeID = context.item.worktreeIdentity.id
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let scroll = SidebarReportScrollView()
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = host
        let content = NSViewController()
        content.view = scroll
        popover.contentViewController = content
        self.popover = popover
        update(view)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    func update(_ view: SidebarReportButtonView) {
        guard anchor === view, let context = view.context, let popover,
              let window = view.window else { return }
        let theme = view.theme
        let width = min(380, max(1, window.contentLayoutRect.width - 24))
        host.rootView = AnyView(
            SidebarWorktreeReportContent(context: context, foreground: theme.foreground,
                                         secondary: theme.foreground.opacity(0.8))
                .padding(16)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.highlightedWorktreeBackground)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        )
        let height = ceil(host.fittingSize.height)
        host.setFrameSize(NSSize(width: width, height: height))
        popover.appearance = theme.nsAppearance
        if let scroll = popover.contentViewController?.view as? SidebarReportScrollView {
            scroll.backgroundColor = theme.highlightedWorktreeBackgroundNSColor
            scroll.borderColor = NSColor(theme.foreground.opacity(0.2))
            scroll.needsDisplay = true
        }
        let size = NSSize(width: width, height: min(height, 540, max(1, window.contentLayoutRect.height - 24)))
        popover.contentViewController?.view.setFrameSize(size)
        popover.contentSize = size
    }

    func removed(_ view: SidebarReportButtonView) { if anchor === view { close() } }

    func close() {
        popover?.delegate = nil
        popover?.close()
        popover = nil
        anchor = nil
        activeID = nil
    }

    func popoverDidClose(_ notification: Notification) { close() }
}

private final class SidebarReportScrollView: NSScrollView {
    var borderColor: NSColor = .separatorColor
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        borderColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

/// An AppKit button owns its click independently of the enclosing worktree-selection
/// button. Merely hovering or tabbing to it never presents a report.
final class SidebarReportButtonView: NSButton {
    weak var controller: SidebarReportController?
    var context: SidebarWorktreeContext?
    var theme: GhosttyTheme = .fallback

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Show report")
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(showReport)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func showReport() { controller?.show(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.removed(self) }
    }
}

struct SidebarReportButton: NSViewRepresentable {
    let controller: SidebarReportController
    let context: SidebarWorktreeContext
    let theme: GhosttyTheme

    func makeNSView(context: Context) -> SidebarReportButtonView { SidebarReportButtonView() }
    func updateNSView(_ view: SidebarReportButtonView, context: Context) {
        view.controller = controller
        view.context = self.context
        view.theme = theme
        view.contentTintColor = NSColor(theme.sidebarSecondaryText)
        view.setAccessibilityLabel("Show report for \(self.context.worktree.displayName)")
        view.toolTip = "Show report"
        controller.update(view)
    }
    static func dismantleNSView(_ view: SidebarReportButtonView, coordinator: ()) { view.controller?.removed(view) }
}

import AppKit
import SwiftUI
import GrafttyCommandUI

@MainActor
final class SidebarReportController: ObservableObject {
    @Published private(set) var activeID: String?
    @Published private(set) var isPinned = false
    private(set) var presentationID = UUID()
    private weak var anchor: SidebarReportAnchorView?
    private var panel: SidebarReportPanel?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func enter(_ view: SidebarReportAnchorView) {
        keepOpen()
        showTask?.cancel()
        guard !isPinned, !view.suppressed else { return }
        showTask = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let view, view.window != nil else { return }
            self.show(view)
        }
    }

    func leave() {
        showTask?.cancel()
        guard !isPinned else { return }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.close()
        }
    }

    func keepOpen() { hideTask?.cancel() }
    func pin() { isPinned = true; keepOpen() }
    func togglePin() { isPinned.toggle(); if isPinned { keepOpen() } }

    func show(_ view: SidebarReportAnchorView, pinned: Bool = false) {
        guard let context = view.context, let window = view.window else { return }
        if isPinned && activeID != context.item.worktreeIdentity.id { return }
        close(suppress: false)
        presentationID = UUID()
        anchor = view
        activeID = context.item.worktreeIdentity.id
        isPinned = pinned
        let panel = SidebarReportPanel()
        panel.onClose = { [weak self] in self?.close() }
        self.panel = panel
        update(view)
        guard self.panel === panel else { return }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if pinned { panel.makeKey(); panel.selectNextKeyView(nil) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            guard event.window === panel || event.window === panel.parent else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.close(); return nil }
            if event.type != .keyDown, !self.isPinned, event.window !== panel { self.close() }
            return event
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
    }

    func update(_ view: SidebarReportAnchorView) {
        guard anchor === view, let context = view.context, let panel else { return }
        let content = SidebarReportPanelContent(controller: self, presentationID: presentationID, context: context,
            onOpen: { [weak view] in await view?.onOpen() ?? false },
            onDismiss: { [weak view] in view?.onDismiss() })
        if let host = panel.contentView as? NSHostingView<SidebarReportPanelContent> { host.rootView = content }
        else { panel.contentView = NSHostingView(rootView: content) }
        position()
    }

    func position() {
        guard let anchor, let panel else { return }
        guard let window = anchor.window,
              !anchor.isHiddenOrHasHiddenAncestor, !anchor.visibleRect.isEmpty else { close(); return }
        let bounds = window.convertToScreen(window.contentLayoutRect)
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(Self.frame(anchor: rect, within: bounds), display: true)
    }

    static func frame(anchor: NSRect, within bounds: NSRect) -> NSRect {
        let width = min(380, max(0, bounds.width - 24))
        let height = min(540, max(0, bounds.height - 24))
        return NSRect(x: max(bounds.minX + 12, min(anchor.maxX + 8, bounds.maxX - width - 12)),
                      y: max(bounds.minY + 12, min(anchor.maxY - height, bounds.maxY - height - 12)),
                      width: width, height: height)
    }

    func removed(_ view: SidebarReportAnchorView) { if anchor === view { close() } }

    func close(presentationID: UUID) {
        guard self.presentationID == presentationID else { return }
        close()
    }

    func close(suppress: Bool = true) {
        showTask?.cancel(); hideTask?.cancel()
        if suppress { anchor?.suppressed = true }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            let parent = panel.parent
            let restoreFocus = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            if restoreFocus {
                parent?.makeKey()
            }
        }
        panel?.orderOut(nil)
        panel = nil
        anchor = nil
        activeID = nil
        isPinned = false
    }
}

private struct SidebarReportPanelContent: View {
    @ObservedObject var controller: SidebarReportController
    let presentationID: UUID
    let context: SidebarWorktreeContext
    let onOpen: () async -> Bool
    let onDismiss: () -> Void
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(controller.isPinned ? "Unpin" : "Pin") { controller.togglePin() }
                    .buttonStyle(.plain).font(.caption)
                    .focused($pinFocused)
                    .accessibilityLabel(controller.isPinned ? "Unpin report" : "Pin report")
            }.padding(.horizontal, 16).padding(.top, 10)
            SidebarWorktreeReport(context: context, onOpen: onOpen, onDismiss: onDismiss,
                                  onClose: { controller.close(presentationID: presentationID) })
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.4)))
        .onHover { inside in if inside { controller.keepOpen() } else { controller.leave() } }
        .onAppear { pinFocused = controller.isPinned }
    }
}

final class SidebarReportPanel: NSPanel {
    var onClose: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

final class SidebarReportAnchorView: NSView {
    weak var controller: SidebarReportController?
    var context: SidebarWorktreeContext?
    var onOpen: () async -> Bool = { false }
    var onDismiss: () -> Void = {}
    var suppressed = false
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { suppressed = false; controller?.enter(self) }
    override func mouseExited(with event: NSEvent) { suppressed = false; controller?.leave() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { controller?.removed(self) } }
    override func layout() { super.layout(); controller?.position() }
}

private struct SidebarReportAnchor: NSViewRepresentable {
    let controller: SidebarReportController
    let context: SidebarWorktreeContext
    let onOpen: () async -> Bool
    let onDismiss: () -> Void
    let capture: (SidebarReportAnchorView) -> Void
    func makeNSView(context: Context) -> SidebarReportAnchorView {
        let view = SidebarReportAnchorView()
        DispatchQueue.main.async { capture(view) }
        return view
    }
    func updateNSView(_ view: SidebarReportAnchorView, context: Context) {
        view.controller = controller; view.context = self.context
        view.onOpen = onOpen; view.onDismiss = onDismiss
        controller.update(view)
    }
    static func dismantleNSView(_ view: SidebarReportAnchorView, coordinator: ()) { view.controller?.removed(view) }
}

struct SidebarReportPreview: ViewModifier {
    @ObservedObject var controller: SidebarReportController
    let context: SidebarWorktreeContext
    let onOpen: () async -> Bool
    let onDismiss: () -> Void
    @State private var anchor: SidebarReportAnchorView?
    @State private var hovered = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .background(SidebarReportAnchor(controller: controller, context: context, onOpen: onOpen,
                                           onDismiss: onDismiss, capture: { anchor = $0 }))
            .onHover { hovered = $0 }
            .overlay(alignment: .topTrailing) {
                Button {
                    if let anchor { controller.show(anchor, pinned: true) }
                } label: {
                    Image(systemName: "ellipsis").font(.caption).frame(width: 24, height: 24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).focused($focused)
                .opacity(hovered || focused ? 1 : 0)
                .accessibilityLabel("Show report for \(context.worktree.displayName)")
                .padding(.trailing, 2)
            }
            .onChange(of: focused) { _, value in
                if value, let anchor, !anchor.suppressed { controller.show(anchor) }
                else if !value { controller.leave() }
            }
            .accessibilityAction(named: "Show report") {
                if let anchor { controller.show(anchor, pinned: true) }
            }
    }
}

struct RemoteReportPreview: ViewModifier {
    let controller: SidebarReportController?
    let context: SidebarWorktreeContext
    let onOpen: (SidebarWorktreeContext) async -> Bool
    let onDismiss: (SidebarWorktreeContext) -> Void
    func body(content: Content) -> some View {
        if let controller {
            content.modifier(SidebarReportPreview(controller: controller, context: context,
                onOpen: { await onOpen(context) }, onDismiss: { onDismiss(context) }))
        } else { content }
    }
}

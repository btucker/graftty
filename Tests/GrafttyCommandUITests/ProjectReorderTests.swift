import CoreTransferable
import Foundation
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI
#if os(macOS)
import AppKit
#endif

@Suite("@spec LAYOUT-2.160: When the user drags a project in the sidebar on Mac or mobile, the application shall show an insertion marker at the hovered row's upper or lower edge and move the project before or after that row only on drop, while rejecting unrelated payloads and disabled reordering.")
struct ProjectReorderTests {
    @Test func appBundlesDeclareProjectDragType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "cat > \"$APP/Contents/Info.plist\" <<PLIST\n")?.upperBound)
        let end = try #require(script.range(of: "\nPLIST", range: start..<script.endIndex)?.lowerBound)
        let mobile = try Data(contentsOf: root.appendingPathComponent("Apps/GrafttyMobile/GrafttyMobile/Info.plist"))
        for data in [Data(script[start..<end].utf8), mobile] {
            let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let declarations = plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
            let declaration = try #require(declarations.first {
                $0["UTTypeIdentifier"] as? String == TransferableProjectMove.contentType.identifier
            })
            #expect((declaration["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
        }
    }

    @Test func projectPayloadRoundTripsThroughItemProvider() async throws {
        let payload = TransferableProjectMove(projectID: "mac:repo")
        let provider = NSItemProvider()
        provider.register(payload)
        let decoded: TransferableProjectMove = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: TransferableProjectMove.self) { continuation.resume(with: $0) }
        }
        #expect(decoded.projectID == payload.projectID)
        #expect(!provider.hasItemConformingToTypeIdentifier("public.text"))
        #expect(!provider.hasItemConformingToTypeIdentifier("com.graftty.sidebar-worktree-move"))
    }

    @Test func insertionUsesActualRowMidpoint() {
        #expect(ProjectDropPlacement(location: CGPoint(x: 5, y: 21), rowHeight: 44) == .before)
        #expect(ProjectDropPlacement(location: CGPoint(x: 5, y: 22), rowHeight: 44) == .after)
        #expect(ProjectDropPlacement(location: CGPoint(x: 5, y: 30), rowHeight: 64) == .before)
        #expect(ProjectDropPlacement(location: CGPoint(x: 5, y: 33), rowHeight: 64) == .after)
    }

    @MainActor @Test func dropMovesOnlyKnownProjectsWhenEnabled() {
        var order = SidebarProjectOrder(ids: ["a", "b", "remote-offline"])
        let move: (String, String, Bool) -> Void = { id, target, after in
            order.move(id, relativeTo: target, after: after)
        }
        let payload = TransferableProjectMove(projectID: "remote-offline")
        #expect(!payload.performMove(to: "a", placement: .before, projectIDs: order.ids, allowsReordering: false, onMove: move))
        #expect(!payload.performMove(to: "missing", placement: .before, projectIDs: order.ids, allowsReordering: true, onMove: move))
        #expect(!payload.performMove(to: "remote-offline", placement: .before, projectIDs: order.ids, allowsReordering: true, onMove: move))
        #expect(!TransferableProjectMove(projectID: "unknown").performMove(to: "a", placement: .before, projectIDs: order.ids, allowsReordering: true, onMove: move))
        #expect(order.ids == ["a", "b", "remote-offline"])
        #expect(payload.performMove(to: "a", placement: .before, projectIDs: order.ids, allowsReordering: true, onMove: move))
        #expect(order.ids == ["remote-offline", "a", "b"])
        #expect(payload.performMove(to: "b", placement: .after, projectIDs: order.ids, allowsReordering: true, onMove: move))
        #expect(order.ids == ["a", "b", "remote-offline"])
    }

    #if os(macOS)
    @MainActor @Test func nativePressSelectsAndDragStartsSessionWithoutSelecting() throws {
        let view = RecordingProjectDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
        let writer = try #require(ProjectDragPasteboardWriter(.init(projectID: "a")))
        view.pasteboardWriter = writer
        var clicks = 0
        view.onClick = { clicks += 1 }
        let down = try event(.leftMouseDown, at: CGPoint(x: 10, y: 10))
        view.mouseDown(with: down)
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 10, y: 10)))
        #expect(clicks == 1)
        view.mouseDown(with: down)
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 12, y: 10)))
        #expect(view.draggedItems.isEmpty)
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 20, y: 10)))
        #expect(view.draggedItems.count == 1)
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 20, y: 10)))
        #expect(clicks == 1)
        let draggedWriter = try #require(view.draggedItems.first?.item as? NSPasteboardWriting)
        let type = NSPasteboard.PasteboardType(TransferableProjectMove.contentType.identifier)
        let data = try #require(draggedWriter.pasteboardPropertyList(forType: type) as? Data)
        #expect(try JSONDecoder().decode(TransferableProjectMove.self, from: data).projectID == "a")
    }

    @MainActor @Test func nativeSourcePreservesContextMenusAndDisabledSelection() throws {
        let view = SidebarRowDragSourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 44))
        let point = CGPoint(x: 10, y: 10)
        #expect(view.hitTest(point, event: try event(.leftMouseDown, at: point)) === view)
        #expect(view.hitTest(point, event: try event(.rightMouseDown, at: point)) == nil)
        #expect(view.hitTest(point, event: try event(.leftMouseDown, at: point, modifiers: .control)) == nil)
        var clicks = 0
        view.onClick = { clicks += 1 }
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 20, y: 10)))
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        #expect(clicks == 1)
    }

    @MainActor @Test(arguments: [false, true])
    func railRowsReceiveNativePresses(collapsed: Bool) async throws {
        let projects = [SidebarProject(id: "a", repositoryID: "a", name: "First"),
                        SidebarProject(id: "b", repositoryID: "b", name: "Offline", isAvailable: false)]
        var selected: [String] = []
        let hosting = NSHostingView(rootView: ProjectNavigationRail(projects: projects, counts: [:], icons: [:], selectedID: "a",
            collapsed: .constant(collapsed), onSelect: { selected.append($0.id) }, onMove: { _, _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: collapsed ? 64 : 196, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let sources = findSources(hosting)
        #expect(sources.count == 2)
        for source in sources {
            let point = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let down = try event(.leftMouseDown, at: point)
            sources.forEach { $0.currentEvent = { down } }
            let hostPoint = try #require(hosting.superview).convert(point, from: nil)
            let hit = try #require(hosting.hitTest(hostPoint))
            #expect(hit === source)
            // Avoid entering a native Button's modal event tracking if hit testing regresses.
            if hit === source {
                hit.mouseDown(with: down)
                hit.mouseUp(with: try event(.leftMouseUp, at: point))
            }
        }
        #expect(Set(selected) == Set(projects.map(\.id)))
    }

    @MainActor private func findSources(_ view: NSView) -> [SidebarRowDragSourceView] {
        if let source = view as? SidebarRowDragSourceView { return [source] }
        return view.subviews.flatMap(findSources)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    #endif
}

#if os(macOS)
@MainActor private final class RecordingProjectDragView: SidebarRowDragSourceView {
    var draggedItems: [NSDraggingItem] = []
    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource) -> NSDraggingSession {
        draggedItems = items
        return NSDraggingSession()
    }
}
#endif

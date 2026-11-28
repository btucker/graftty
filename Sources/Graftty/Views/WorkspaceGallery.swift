import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// The right-hand column beside a workspace, shared by the gallery and Context
/// so that the terminal only ever gives up one column's width (LAYOUT-2.253).
enum WorkspaceGalleryColumn {
    static let galleryWidth: CGFloat = 220
    static let contextWidth: CGFloat = 360
    /// How narrow and how wide the user can drag the column (LAYOUT-2.260).
    static let widthRange: ClosedRange<CGFloat> = 180...600
    static let galleryWidthKey = "workspaceColumnWidth.gallery"
    static let contextWidthKey = "workspaceColumnWidth.context"
    static let contextMinimizedKey = "workspaceSidebar.contextMinimized"
    /// How much of the column the gallery takes above an open Context (LAYOUT-2.267).
    static func galleryMaxHeight(showsContext: Bool, contextMinimized: Bool) -> CGFloat {
        showsContext && !contextMinimized ? 320 : .infinity
    }

    static func width(showsGallery: Bool, showsContext: Bool, galleryWidth: CGFloat = galleryWidth,
                      contextWidth: CGFloat = contextWidth) -> CGFloat? {
        if showsContext { return contextWidth }
        return showsGallery ? galleryWidth : nil
    }

    /// Context takes its width only while open: minimized under the gallery, it is a bar.
    static func showsContext(hasPanel: Bool, showsGallery: Bool, contextMinimized: Bool) -> Bool {
        hasPanel && !(contextMinimized && showsGallery)
    }

    /// `translation` is the drag of the column's leading edge: leftward widens.
    static func resized(_ width: CGFloat, by translation: CGFloat) -> CGFloat {
        min(max(width - translation, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Tiles keep their shape as the column widens.
    static func tileHeight(columnWidth: CGFloat, showsContext: Bool) -> CGFloat {
        (128 * columnWidth / (showsContext ? contextWidth : galleryWidth)).rounded()
    }
}

private struct WorkspaceColumnMetricsKey: EnvironmentKey {
    static let defaultValue = (width: WorkspaceGalleryColumn.galleryWidth, tileHeight: CGFloat(128))
}

extension EnvironmentValues {
    /// The right-hand column's width and the tile height that goes with it.
    var workspaceColumnMetrics: (width: CGFloat, tileHeight: CGFloat) {
        get { self[WorkspaceColumnMetricsKey.self] }
        set { self[WorkspaceColumnMetricsKey.self] = newValue }
    }
}

/// The gallery above Context in one column whose leading edge drags to resize
/// it (LAYOUT-2.253, LAYOUT-2.260).
struct WorkspaceRightColumn<Gallery: View>: View {
    let showsGallery: Bool
    let contextPanel: AnyView?
    let separator: Color
    @ViewBuilder let gallery: () -> Gallery
    @AppStorage(WorkspaceGalleryColumn.galleryWidthKey) private var galleryWidth = Double(WorkspaceGalleryColumn.galleryWidth)
    @AppStorage(WorkspaceGalleryColumn.contextWidthKey) private var contextWidth = Double(WorkspaceGalleryColumn.contextWidth)
    @AppStorage(WorkspaceGalleryColumn.contextMinimizedKey) private var contextMinimized = false
    @State private var resizeStart: CGFloat?
    @State private var pushedResizeCursor = false

    /// Balanced, so a column removed under the pointer leaves no cursor behind.
    private func setResizeCursor(_ shown: Bool) {
        guard shown != pushedResizeCursor else { return }
        pushedResizeCursor = shown
        if shown { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }

    /// Minimized Context: a bar at the foot of the column that opens it again.
    private var contextBar: some View {
        Button { contextMinimized = false } label: {
            HStack(spacing: 6) {
                Text("Context").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.2").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show context")
        .accessibilityLabel("Show context")
    }

    var body: some View {
        // Minimized Context is a bar: the column is then the gallery's own width (LAYOUT-2.260).
        let showsContext = WorkspaceGalleryColumn.showsContext(hasPanel: contextPanel != nil, showsGallery: showsGallery,
                                                               contextMinimized: contextMinimized)
        if let stored = WorkspaceGalleryColumn.width(showsGallery: showsGallery, showsContext: showsContext,
                                                     galleryWidth: galleryWidth, contextWidth: contextWidth) {
            let width = WorkspaceGalleryColumn.resized(stored, by: 0)
            VStack(spacing: 0) {
                if showsGallery {
                    gallery().frame(maxHeight: WorkspaceGalleryColumn.galleryMaxHeight(showsContext: showsContext,
                                                                                         contextMinimized: contextMinimized))
                }
                if let contextPanel {
                    if showsGallery { separator.frame(height: 1) }
                    if contextMinimized && showsGallery { contextBar.opacity(0.6) } else { contextPanel.frame(maxHeight: .infinity) }
                }
            }
            .environment(\.workspaceColumnMetrics,
                         (width, WorkspaceGalleryColumn.tileHeight(columnWidth: width, showsContext: showsContext)))
            .frame(width: width)
            // The worktree's colour runs on from the header (LAYOUT-2.265).
            .background(alignment: .top) { WorktreeColumnWash() }
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { setResizeCursor($0) }
                    .onDisappear { setResizeCursor(false) }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = resizeStart ?? width
                            resizeStart = start
                            let resized = Double(WorkspaceGalleryColumn.resized(start, by: value.translation.width))
                            if showsContext { contextWidth = resized } else { galleryWidth = resized }
                        }
                        .onEnded { _ in resizeStart = nil })
                    .offset(x: -3)
                    .help("Drag to resize")
                    .accessibilityLabel("Agents column width")
            }
            // Above the stage, so tile rail cards can spill over it.
            .zIndex(1)
        }
    }
}

/// One agent's tile, as the gallery needs it.
/// Scrolls the agent a tile rail just put on stage to the message it pointed
/// at (CONTEXT-57.15). Staging can resize the terminal and reflow its rows,
/// so the jump finds the message again once the staged surface has settled.
@MainActor
enum MacGalleryJump {
    private static var task: Task<Void, Never>?

    static func reveal(_ eventID: String, timeline: WorktreeTimeline?, handle: @escaping @MainActor () -> SurfaceHandle?) {
        let messages = timeline.map(ScrollbackMap.messages(in:)) ?? []
        task?.cancel()
        task = Task {
            _ = await StagedMessageReveal.reveal {
                guard let handle = handle() else { return false }
                if let row = handle.scrollbackMapModel.map?.row(for: eventID) {
                    handle.scrollbackMapModel.scroll(toRow: row)
                    return true
                }
                return await handle.reveal(eventID: eventID, messages: messages)
            }
        }
    }
}

struct WorkspaceGalleryTileModel: Identifiable {
    /// The drag payload and the key the callbacks receive.
    let id: String
    /// Looked up when drawn, not when the tile is built: a surface created
    /// later, as at launch, changes nothing the gallery observes (LAYOUT-2.258).
    let handle: @MainActor () -> SurfaceHandle?
    let title: String
    /// Whose logo the tile shows (LAYOUT-2.263).
    let provider: String?
    let status: AgentTileStatus
    let isOnStage: Bool
    let scrollback: AgentScrollbackMap?
}

/// Every agent in the worktree as a live tile, in the user's tile order, with
/// an empty tile at the end for starting another.
struct WorkspaceGallery<NewAgent: View, TileMenu: View>: View {
    let tiles: [WorkspaceGalleryTileModel]
    let theme: GhosttyTheme
    let onStage: (String) -> Void
    /// A tile's id and the event ID of the message its rail activated.
    let onJump: (String, String) -> Void
    let onMove: (String, String, Bool) -> Void
    @ViewBuilder let newAgent: () -> NewAgent
    @ViewBuilder let tileMenu: (String) -> TileMenu
    @State private var activeRail: String?
    @AppStorage(AgentGalleryFinished.expandedKey) private var showsFinished = false
    @Environment(\.workspaceColumnMetrics) private var column

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.foreground.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 28)
            // Tiles scroll unclipped so rail cards can spill out; they pass under the header.
            // The opaque header repeats the column's wash, which starts at the same top edge.
            .background {
                theme.background.overlay(theme.foreground.opacity(0.03))
                    .overlay(alignment: .top) { WorktreeColumnWash() }.clipped()
            }
            .zIndex(1)
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    let split = AgentGalleryFinished.split(tiles) { $0.status }
                    ForEach(split.active) { tile($0, finished: false) }
                    newAgent()
                        .frame(height: 44)
                    if !split.finished.isEmpty {
                        AgentGalleryFinishedHeader(count: split.finished.count, isExpanded: $showsFinished,
                                                   foreground: theme.foreground)
                        if showsFinished { ForEach(split.finished) { tile($0, finished: true) } }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            // Preview cards extend past the tiles, over the stage.
            .scrollClipDisabled()
        }
        .background(theme.foreground.opacity(0.03))
        .overlay(alignment: .leading) { theme.foreground.opacity(0.08).frame(width: 1) }
    }

    private func tile(_ tile: WorkspaceGalleryTileModel, finished: Bool) -> some View {
        AgentGalleryTile(title: tile.title, provider: tile.provider, status: tile.status, isOnStage: tile.isOnStage,
                         foreground: theme.foreground, background: theme.background, compact: finished,
                         decorateBody: { body in
                             AnyView(body
                                .workspaceTabDragSource(tile.id, onSelect: { onStage(tile.id) })
                                .contextMenu { tileMenu(tile.id) })
                         }) {
            MacTerminalThumbnail(handle: tile.handle, fallback: tile.status.caption, foreground: theme.foreground)
        } rail: {
            if let scrollback = tile.scrollback {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let handle = tile.handle() {
                        ScrollbackMapOverlayHost(model: handle.scrollbackMapModel, timeline: scrollback.timeline,
                            recovery: scrollback.recovery, previewOverhang: 240,
                            previewWidth: column.width + 240,
                            onJump: { onJump(tile.id, $0) })
                            .padding(.vertical, 4)
                            .id(ObjectIdentifier(handle))
                    }
                }
            }
        }
        .frame(height: finished ? AgentGalleryFinished.rowHeight : column.tileHeight)
        // The tile body is a native click and drag source with no press of its own for VoiceOver.
        .accessibilityAction { onStage(tile.id) }
        .modifier(WorkspaceTabDropTarget(vertical: true) { source, after in onMove(source, tile.id, after) })
        // A tile whose rail is in use draws above the next, which its cards overlap.
        .onPreferenceChange(ScrollbackMapActive.self) { active in
            if active { activeRail = tile.id } else if activeRail == tile.id { activeRail = nil }
        }
        .zIndex(activeRail == tile.id ? 1 : 0)
    }
}

/// A miniature of an agent's terminal drawn from its text once a second. It
/// reads the surface without mounting it, so the terminal's grid never changes.
private struct MacTerminalThumbnail: View {
    let handle: @MainActor () -> SurfaceHandle?
    let fallback: String
    let foreground: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let handle = handle() {
                TerminalTextThumbnail(rows: handle.screenRows(), columns: Int(handle.queryGridSize().columns),
                                      foreground: foreground)
            } else {
                Text(fallback).font(.system(size: 9)).foregroundStyle(foreground.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
            }
        }
    }
}

/// What floats over the top of a stage pane: a live input request, then, for
/// a lone pane, its Chat / Terminal switch at the trailing corner, so the
/// request never runs under it (LAYOUT-2.257).
struct StagePaneTopControls: View {
    let banner: AnyView?
    let chatSwitch: AnyView?

    var isEmpty: Bool { banner == nil && !hasControls }
    private var hasControls: Bool { chatSwitch != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let banner { banner } else { Spacer(minLength: 0) }
            if hasControls {
                chatSwitch.padding(.top, 6)
            }
        }
        // Clear of the terminal's scroll rail.
        .padding(.trailing, hasControls ? 22 : 0)
    }
}

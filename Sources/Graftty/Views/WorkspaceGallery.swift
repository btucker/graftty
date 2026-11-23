import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// The right-hand column beside a workspace, shared by the gallery and Context
/// so that the terminal only ever gives up one column's width (LAYOUT-2.252).
enum WorkspaceGalleryColumn {
    static let galleryWidth: CGFloat = 220
    static let contextWidth: CGFloat = 360

    static func width(showsGallery: Bool, showsContext: Bool) -> CGFloat? {
        if showsContext { return contextWidth }
        return showsGallery ? galleryWidth : nil
    }
}

/// One agent's tile, as the gallery needs it.
struct WorkspaceGalleryTileModel: Identifiable {
    /// The drag payload and the key the callbacks receive.
    let id: String
    let handle: SurfaceHandle?
    let title: String
    let status: AgentTileStatus
    let isOnStage: Bool
    let scrollback: AgentScrollbackMap?
}

/// Every agent in the worktree as a live tile, in the user's tile order, with
/// an empty tile at the end for starting another.
struct WorkspaceGallery<NewAgent: View, TileMenu: View>: View {
    static var tileHeight: CGFloat { 128 }

    let tiles: [WorkspaceGalleryTileModel]
    let theme: GhosttyTheme
    let onStage: (String) -> Void
    let onJump: (String, Int) -> Void
    let onMove: (String, String, Bool) -> Void
    let onCollapse: () -> Void
    @ViewBuilder let newAgent: () -> NewAgent
    @ViewBuilder let tileMenu: (String) -> TileMenu

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.foreground.opacity(0.55))
                Spacer()
                Button(action: onCollapse) { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.plain).foregroundStyle(theme.foreground.opacity(0.6))
                    .help("Hide agents")
            }
            .padding(.horizontal, 10).frame(height: 28)
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(tiles) { tile in
                        AgentGalleryTile(title: tile.title, status: tile.status, isOnStage: tile.isOnStage,
                                         foreground: theme.foreground, background: theme.background,
                                         decorateBody: { body in
                                             AnyView(body
                                                .workspaceTabDragSource(tile.id, onSelect: { onStage(tile.id) })
                                                .contextMenu { tileMenu(tile.id) })
                                         }) {
                            MacTerminalThumbnail(handle: tile.handle, fallback: tile.status.caption, foreground: theme.foreground)
                        } rail: {
                            if let handle = tile.handle, let scrollback = tile.scrollback {
                                ScrollbackMapOverlayHost(model: handle.scrollbackMapModel, timeline: scrollback.timeline,
                                    recovery: scrollback.recovery, previewOverhang: 240,
                                    previewWidth: WorkspaceGalleryColumn.galleryWidth + 240,
                                    onJump: { onJump(tile.id, $0) })
                                    .padding(.vertical, 4)
                            }
                        }
                        .frame(height: Self.tileHeight)
                        .modifier(WorkspaceTabDropTarget(vertical: true) { source, after in onMove(source, tile.id, after) })
                    }
                    newAgent()
                        .frame(height: 44)
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            // Preview cards extend past the tiles, over the stage.
            .scrollClipDisabled()
        }
        .background(theme.foreground.opacity(0.03))
        .overlay(alignment: .leading) { theme.foreground.opacity(0.08).frame(width: 1) }
    }
}

/// A miniature of an agent's terminal drawn from its text once a second. It
/// reads the surface without mounting it, so the terminal's grid never changes.
private struct MacTerminalThumbnail: View {
    let handle: SurfaceHandle?
    let fallback: String
    let foreground: Color

    var body: some View {
        if let handle {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let size = handle.queryGridSize()
                TerminalTextThumbnail(rows: handle.scrollbackRows(limit: Int(max(1, size.rows)))?.rows ?? [],
                                      columns: Int(size.columns), foreground: foreground)
            }
        } else {
            Text(fallback).font(.system(size: 9)).foregroundStyle(foreground.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
        }
    }
}

/// While the gallery is collapsed, a small control at the stage's corner opens
/// it: a plus with one agent, else the number of agents asking for the user.
struct WorkspaceGalleryOpener: View {
    let agentCount: Int
    let askingCount: Int
    let theme: GhosttyTheme
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                if askingCount > 0 {
                    AgentStatusDot(dot: .asking)
                    Text("\(askingCount)").monospacedDigit()
                } else if agentCount <= 1 {
                    Image(systemName: "plus")
                } else {
                    Image(systemName: "rectangle.stack")
                    Text("\(agentCount)").monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.foreground.opacity(0.8))
        .help(agentCount <= 1 ? "Show agents and start another" : "Show agents")
        .accessibilityLabel(askingCount > 0 ? "Show agents, \(askingCount) asking" : "Show agents")
    }
}

#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI
import UIKit

/// Renders a `PaneLayoutNode` tree as nested rectangles that mirror the
/// Mac sidebar's split layout. Leaves become tappable tiles labelled
/// with the pane's current title. Each split respects its ratio: a
/// horizontal split divides width by `ratio` (left takes that fraction);
/// a vertical split divides height. Works recursively for any depth.
public struct PaneLayoutView: View {
    public let layout: PaneLayoutNode
    public let baseConfig: String?
    public let previewClient: (_ sessionName: String) -> SessionClient?
    public let onSelect: (_ sessionName: String) -> Void
    public let preferredInterfaceStyle: UIUserInterfaceStyle

    public init(
        layout: PaneLayoutNode,
        baseConfig: String? = "",
        previewClient: @escaping (_ sessionName: String) -> SessionClient? = { _ in nil },
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        onSelect: @escaping (_ sessionName: String) -> Void
    ) {
        self.layout = layout
        self.baseConfig = baseConfig
        self.previewClient = previewClient
        self.onSelect = onSelect
        self.preferredInterfaceStyle = preferredInterfaceStyle
    }

    public var body: some View {
        GeometryReader { geo in
            render(layout, in: geo.size)
        }
        .padding(8)
    }

    /// Recursive, so has to return `AnyView` — Swift can't infer an
    /// opaque `some View` that references itself.
    private func render(_ node: PaneLayoutNode, in size: CGSize) -> AnyView {
        switch node {
        case let .leaf(sessionName, title, _, _, _):
            return AnyView(PaneTile(
                title: title.isEmpty ? sessionName : title,
                baseConfig: baseConfig,
                client: previewClient(sessionName),
                preferredInterfaceStyle: preferredInterfaceStyle
            ) {
                onSelect(sessionName)
            })

        case let .split(direction, ratio, left, right):
            switch direction {
            case .horizontal:
                let leftWidth = max(0, size.width * CGFloat(ratio) - 2)
                let rightWidth = max(0, size.width * CGFloat(1 - ratio) - 2)
                return AnyView(HStack(spacing: 4) {
                    render(left, in: CGSize(width: leftWidth, height: size.height))
                        .frame(width: leftWidth)
                    render(right, in: CGSize(width: rightWidth, height: size.height))
                        .frame(width: rightWidth)
                })
            case .vertical:
                let topHeight = max(0, size.height * CGFloat(ratio) - 2)
                let bottomHeight = max(0, size.height * CGFloat(1 - ratio) - 2)
                return AnyView(VStack(spacing: 4) {
                    render(left, in: CGSize(width: size.width, height: topHeight))
                        .frame(height: topHeight)
                    render(right, in: CGSize(width: size.width, height: bottomHeight))
                        .frame(height: bottomHeight)
                })
            }
        }
    }
}

/// Leaf in the split tree — a tappable rounded rect with the pane title.
/// When `client == nil` (single-pane worktrees skip the preview pool per
/// IOS-4.14), renders a static centered title with no controller, no
/// preview client, no WebSocket. Otherwise owns its own `TerminalController`,
/// sized so the authoritative grid fits the tile width without an outer
/// scaleEffect downscale (IOS-4.12).
///
/// @spec IOS-11.11: While a pane is rendered as a worktree-detail preview tile (`IOS-4.10`), the long-press selection menu shall not be installed; tapping the tile shall continue to open the fullscreen pane per `IOS-4.21`.
/// Guaranteed by `.allowsHitTesting(false)` applied to the inner `TerminalPaneView` in `paneContent` — `TerminalInputContainerView`'s long-press gesture recogniser never receives touches. The `onPasteRequested` closure is also left `nil` at the `TerminalPaneView` call site.
private struct PaneTile: View {
    let title: String
    let baseConfig: String?
    let client: SessionClient?
    let preferredInterfaceStyle: UIUserInterfaceStyle
    let onTap: () -> Void

    @State private var controller: TerminalController?
    @State private var controllerSourceConfig: String?
    @State private var lastAppliedFontSize: Float?

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay {
                    if let client {
                        livePreview(client: client)
                    } else {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func livePreview(client: SessionClient) -> some View {
        GeometryReader { geo in
            let width = geo.size.width.rounded(.toNearestOrAwayFromZero)
            ZStack(alignment: .bottomLeading) {
                paneContent(client: client)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
            }
            .task(id: SizingKey(width: width, cols: client.authoritativeGrid?.cols, baseConfig: baseConfig)) {
                resizeController(tileWidth: width, authoritativeCols: client.authoritativeGrid?.cols)
            }
        }
    }

    /// Renders the per-tile controller at the tile's natural width and
    /// trusts `PanePreviewFontSizing` to have sized the font for fit.
    /// Deliberately does NOT apply a `scaleEffect` driven by
    /// `client.cellWidthPoints`: that value is updated by libghostty's
    /// resize callback and shared with the fullscreen view, which renders
    /// at a much larger font, so a feedback-loop safety-net would
    /// oscillate / progressively shrink the preview. The explicit
    /// `frame + clipped` keeps libghostty's Metal layer from rendering
    /// outside the tile if its intrinsic size briefly disagrees.
    @ViewBuilder
    private func paneContent(client: SessionClient) -> some View {
        if let controller, controllerSourceConfig == baseConfig {
            switch client.renderActivity {
            case .active:
                TerminalPaneView(
                    session: client.session,
                    controller: controller,
                    renderPace: client.renderPace,
                    onUserInteraction: { [weak client] in client?.wakeRenderer() },
                    preferredInterfaceStyle: preferredInterfaceStyle,
                    onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) }
                )
                    .allowsHitTesting(false)
                    .overlay(Color.black.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            case .idle:
                IdleSnapshotView(snapshot: client.idleSnapshot) {
                    client.wakeRenderer()
                }
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        } else {
            Color.black.overlay(ProgressView().tint(.white))
        }
    }

    /// Compute a font-size that makes `cols × cellWidth ≈ tileWidth`, so
    /// libghostty's natural unscaled render fits the tile. The 0.6 aspect
    /// is an approximation for Berkeley/SF/JetBrains-style monospace fonts;
    /// a small safety margin (×0.95) keeps us from edge-cases where the
    /// real cell width nudges over the tile width.
    private func resizeController(tileWidth: CGFloat, authoritativeCols: UInt16?) {
        guard let baseConfig else {
            controller = nil
            controllerSourceConfig = nil
            lastAppliedFontSize = nil
            return
        }

        let action = PanePreviewFontApplication.decide(
            tileWidth: tileWidth,
            authoritativeCols: authoritativeCols,
            hasController: controller != nil,
            sourceConfigMatches: controllerSourceConfig == baseConfig,
            lastAppliedFontSize: lastAppliedFontSize
        )
        switch action {
        case .nothing:
            return
        case let .recreateController(fontSize):
            controller = MobileTerminalControllerFactory.makePreview(
                configText: baseConfig,
                fontSize: fontSize
            )
            controllerSourceConfig = baseConfig
            lastAppliedFontSize = fontSize
        case let .applyFont(fontSize):
            controller?.setTerminalConfiguration(
                TerminalConfiguration().fontSize(fontSize)
            )
            lastAppliedFontSize = fontSize
        }
    }

    private struct SizingKey: Hashable {
        let width: CGFloat
        let cols: UInt16?
        let baseConfig: String?
    }
}
#endif

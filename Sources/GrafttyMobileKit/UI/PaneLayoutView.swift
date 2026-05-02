#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

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

    public init(
        layout: PaneLayoutNode,
        baseConfig: String? = "",
        previewClient: @escaping (_ sessionName: String) -> SessionClient? = { _ in nil },
        onSelect: @escaping (_ sessionName: String) -> Void
    ) {
        self.layout = layout
        self.baseConfig = baseConfig
        self.previewClient = previewClient
        self.onSelect = onSelect
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
        case let .leaf(sessionName, title):
            return AnyView(PaneTile(
                title: title.isEmpty ? sessionName : title,
                baseConfig: baseConfig,
                client: previewClient(sessionName)
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
/// Each tile owns its own `TerminalController`, sized so the server's
/// grid fits the tile's width without an outer scaleEffect downscale.
private struct PaneTile: View {
    let title: String
    let baseConfig: String?
    let client: SessionClient?
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
                .overlay(preview)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            let width = geo.size.width.rounded(.toNearestOrAwayFromZero)
            ZStack(alignment: .bottomLeading) {
                paneContent
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
            .task(id: SizingKey(width: width, cols: client?.serverGrid?.cols, baseConfig: baseConfig)) {
                resizeController(tileWidth: width, cols: client?.serverGrid?.cols)
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if let controller, controllerSourceConfig == baseConfig {
            if let client {
                MiniTerminalPreview(controller: controller, client: client)
            } else {
                Color.black
            }
        } else {
            Color.black.overlay(ProgressView().tint(.white))
        }
    }

    /// Compute a font-size that makes `cols × cellWidth ≈ tileWidth`, so
    /// libghostty's natural unscaled render fits the tile. The 0.6 aspect
    /// is an approximation for Berkeley/SF/JetBrains-style monospace fonts;
    /// a small safety margin (×0.95) keeps us from edge-cases where the
    /// real cell width nudges over the tile width and forces scaleEffect.
    private func resizeController(tileWidth: CGFloat, cols: UInt16?) {
        guard let baseConfig else {
            controller = nil
            controllerSourceConfig = nil
            lastAppliedFontSize = nil
            return
        }

        let fontSize = PanePreviewFontSizing.fontSize(
            tileWidth: Double(tileWidth),
            serverCols: cols
        )
        if let controller, controllerSourceConfig == baseConfig {
            guard lastAppliedFontSize != fontSize else { return }
            controller.setTerminalConfiguration(
                TerminalConfiguration().fontSize(fontSize)
            )
            lastAppliedFontSize = fontSize
        } else {
            controller = MobileTerminalControllerFactory.makePreview(
                configText: baseConfig,
                fontSize: fontSize
            )
            controllerSourceConfig = baseConfig
            lastAppliedFontSize = fontSize
        }
    }

    private struct SizingKey: Hashable {
        let width: CGFloat
        let cols: UInt16?
        let baseConfig: String?
    }
}

private struct MiniTerminalPreview: View {
    let controller: TerminalController
    let client: SessionClient

    var body: some View {
        GeometryReader { geo in
            let renderWidth = max(
                geo.size.width,
                CGFloat(client.serverGrid?.cols ?? 0) * (client.cellWidthPoints ?? TerminalWidthLayout.fallbackCellWidth)
            )
            let scale = renderWidth > 0 ? min(1, geo.size.width / renderWidth) : 1

            TerminalPaneView(session: client.session, controller: controller)
                .frame(width: renderWidth, height: geo.size.height / max(scale, 0.01))
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
                .overlay(Color.black.opacity(0.08))
        }
    }
}
#endif

import CoreGraphics

/// Keeps the terminal's pixel grid independent of the containing SwiftUI view.
enum TerminalSnapshotCanvas {
    struct Layout: Equatable {
        let size: CGSize
        let scale: CGFloat
        let center: CGPoint
    }

    static func layout(
        grid: CGSize,
        measuredGrid: CGSize,
        measuredPixels: CGSize,
        cellPixels: CGSize,
        displayScale: CGFloat,
        container: CGSize
    ) -> Layout? {
        guard grid.width > 0, grid.height > 0,
              cellPixels.width > 0, cellPixels.height > 0,
              displayScale > 0, container.width > 0, container.height > 0 else { return nil }
        // Preserve padding and any fractional-cell pixel remainder. Using a
        // font-aspect estimate cannot produce an exact native row count.
        let pixels = CGSize(
            width: measuredPixels.width + (grid.width - measuredGrid.width) * cellPixels.width,
            height: measuredPixels.height + (grid.height - measuredGrid.height) * cellPixels.height
        )
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let size = CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
        let scale = min(container.width / size.width, container.height / size.height)
        guard scale.isFinite, scale > 0 else { return nil }
        return Layout(
            size: size, scale: scale,
            center: CGPoint(x: container.width / 2, y: container.height / 2)
        )
    }
}

import CoreGraphics

/// Keeps the terminal's pixel grid independent of the containing SwiftUI view.
public enum FollowerTerminalLayout {
    public static func additionalHistoryRows(containerHeight: CGFloat, screenHeight: CGFloat,
                                      rowHeight: CGFloat, columns: UInt16,
                                      precedingRows: UInt64) -> UInt32 {
        guard rowHeight.isFinite, rowHeight > 0, columns > 0,
              containerHeight.isFinite, screenHeight.isFinite else { return 0 }
        let capacity = max(0, floor((containerHeight - screenHeight) / rowHeight))
        return UInt32(min(capacity, CGFloat(precedingRows), CGFloat(min(UInt32(UInt16.max), 262144 / UInt32(columns)))))
    }

    public struct Layout: Equatable {
        public let size: CGSize
        public let scale: CGFloat
    }

    public static func layout(
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
        let scale = container.width / size.width
        guard scale.isFinite, scale > 0 else { return nil }
        return Layout(
            size: size, scale: scale
        )
    }
}

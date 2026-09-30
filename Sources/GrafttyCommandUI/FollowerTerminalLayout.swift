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

        public func presentation(
            viewport: CGSize, nativeRowHeight: CGFloat, historyRows: UInt64,
            zoomScale: CGFloat = 1, maximumBaseScale: CGFloat = .infinity,
            fillsSpareHeightWithHistory: Bool = true
        ) -> Presentation {
            let scale = min(scale, maximumBaseScale) * zoomScale
            let screen = CGSize(width: size.width * scale, height: size.height * scale)
            return Presentation(
                scale: scale, rowHeight: nativeRowHeight * scale, screen: screen,
                viewport: viewport, historyRows: historyRows,
                fillsSpareHeightWithHistory: fillsSpareHeightWithHistory
            )
        }
    }

    /// Geometry shared by the native Mac and mobile scroll containers.
    /// The terminal's bounds remain `Layout.size`; only its presentation changes.
    public struct Presentation {
        public let scale: CGFloat
        public let rowHeight: CGFloat
        private let screen: CGSize
        private let viewport: CGSize
        private let historyRows: UInt64
        private let fillsSpareHeightWithHistory: Bool

        fileprivate init(scale: CGFloat, rowHeight: CGFloat, screen: CGSize,
                         viewport: CGSize, historyRows: UInt64, fillsSpareHeightWithHistory: Bool) {
            self.scale = scale
            self.rowHeight = rowHeight
            self.screen = screen
            self.viewport = viewport
            self.historyRows = historyRows
            self.fillsSpareHeightWithHistory = fillsSpareHeightWithHistory
        }

        public var contentSize: CGSize {
            CGSize(width: max(viewport.width, screen.width),
                   height: CGFloat(historyRows) * rowHeight + max(viewport.height, screen.height))
        }

        public func screenFrame(at row: UInt64) -> CGRect {
            let spareHeight = max(0, viewport.height - screen.height)
            return CGRect(
                x: (contentSize.width - screen.width) / 2,
                y: CGFloat(row) * rowHeight + spareHeight / (fillsSpareHeightWithHistory ? 1 : 2),
                width: screen.width, height: screen.height
            )
        }

        public func anchoredOffset(from oldFrame: CGRect, oldOffset: CGPoint,
                                   to newFrame: CGRect, anchor: CGPoint) -> CGPoint {
            let ratio = newFrame.width / oldFrame.width
            return CGPoint(
                x: min(max(0, newFrame.minX + (oldOffset.x + anchor.x - oldFrame.minX) * ratio - anchor.x),
                       max(0, contentSize.width - viewport.width)),
                y: min(max(0, newFrame.minY + (oldOffset.y + anchor.y - oldFrame.minY) * ratio - anchor.y),
                       max(0, contentSize.height - viewport.height))
            )
        }
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

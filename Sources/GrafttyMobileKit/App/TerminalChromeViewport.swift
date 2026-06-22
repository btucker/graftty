import CoreGraphics

enum TerminalChromeViewport {
    static func terminalSize(container: CGSize, chromeHeight: CGFloat?) -> CGSize {
        let reservedHeight = max(0, chromeHeight ?? 0)
        return CGSize(
            width: container.width,
            height: max(1, container.height - reservedHeight)
        )
    }
}

struct TerminalFontFitTaskKey: Hashable {
    /// Whole-point buckets. SwiftUI delivers container sizes that jitter
    /// by sub-points across layout passes during rotation / keyboard
    /// show-hide animations; rounding keeps the task from re-firing on
    /// micro-resizes that produce no perceptible layout change.
    let containerWidthPoints: Int
    let containerHeightPoints: Int
    let authoritativeCols: UInt16?
    let isOwner: Bool
    let baseConfig: String?

    init(
        containerSize: CGSize,
        authoritativeCols: UInt16?,
        isOwner: Bool,
        baseConfig: String?
    ) {
        self.containerWidthPoints = Int(containerSize.width.rounded())
        self.containerHeightPoints = Int(containerSize.height.rounded())
        self.authoritativeCols = authoritativeCols
        self.isOwner = isOwner
        self.baseConfig = baseConfig
    }
}

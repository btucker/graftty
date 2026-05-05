public enum PanePreviewFontSizing {
    public static let defaultColumns = 80
    public static let monospaceAspect = 0.6
    public static let safetyScale = 0.95
    public static let minimumFontSize: Float = 2

    public static func fontSize(tileWidth: Double, serverCols: UInt16?) -> Float {
        guard tileWidth > 0 else { return minimumFontSize }
        let effectiveCols = max(1, Int(serverCols ?? UInt16(defaultColumns)))
        let targetCellWidth = (tileWidth / Double(effectiveCols)) * safetyScale
        return max(minimumFontSize, Float(targetCellWidth / monospaceAspect))
    }
}

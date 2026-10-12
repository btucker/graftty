import Foundation
import GrafttyProtocol

/// Coordinates are relative to the fitted image, excluding letterboxing.
enum ChromeTabCoordinates {
    static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(size.width / CGFloat(ChromeTabFrame.viewportWidth), size.height / CGFloat(ChromeTabFrame.viewportHeight))
        let width = CGFloat(ChromeTabFrame.viewportWidth) * scale
        let height = CGFloat(ChromeTabFrame.viewportHeight) * scale
        let x = (point.x - (size.width - width) / 2) / width
        let y = (point.y - (size.height - height) / 2) / height
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}


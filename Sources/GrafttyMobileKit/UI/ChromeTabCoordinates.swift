import Foundation
import GrafttyProtocol

/// Coordinates are relative to the fitted image, excluding letterboxing.
enum ChromeTabCoordinates {
    static func normalized(_ point: CGPoint, in size: CGSize,
                           imageSize: CGSize = CGSize(width: ChromeTabFrame.viewportWidth, height: ChromeTabFrame.viewportHeight)) -> CGPoint? {
        guard size.width > 0, size.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (point.x - (size.width - width) / 2) / width
        let y = (point.y - (size.height - height) / 2) / height
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

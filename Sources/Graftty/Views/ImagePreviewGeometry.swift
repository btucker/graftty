import Foundation

/// Constrains a movable preview to terminal content without changing its grid.
enum ImagePreviewGeometry {
    static let minimumWidth: CGFloat = 320
    static let minimumHeight: CGFloat = 120

    static func initialFrame(in viewport: CGSize) -> CGRect {
        CGRect(origin: .zero, size: CGSize(width: max(0, viewport.width),
                                          height: ImagePreviewLayout.trayHeight(paneHeight: viewport.height)))
    }

    static func constrained(_ frame: CGRect, in viewport: CGSize) -> CGRect {
        let width = max(0, viewport.width), height = max(0, viewport.height)
        let maximumHeight = height - min(96, height * 0.25)
        let minimumHeight = min(Self.minimumHeight, ImagePreviewLayout.trayHeight(paneHeight: height))
        let size = CGSize(width: min(width, max(min(Self.minimumWidth, width), frame.width)),
                          height: min(maximumHeight, max(minimumHeight, frame.height)))
        return CGRect(x: min(max(0, frame.minX), width - size.width),
                      y: min(max(0, frame.minY), height - size.height), width: size.width, height: size.height)
    }

    static func moving(_ frame: CGRect, by translation: CGSize, in viewport: CGSize) -> CGRect {
        constrained(frame.offsetBy(dx: translation.width, dy: translation.height), in: viewport)
    }

    static func resizing(_ frame: CGRect, by translation: CGSize, in viewport: CGSize) -> CGRect {
        // Resize from the lower-right grip, keeping the upper-left corner anchored.
        let available = CGSize(width: max(0, viewport.width - frame.minX), height: max(0, viewport.height - frame.minY))
        let desired = CGRect(origin: frame.origin,
                             size: CGSize(width: min(available.width, frame.width + translation.width),
                                          height: min(available.height, frame.height + translation.height)))
        return constrained(desired, in: viewport)
    }
}

enum ImagePreviewInteraction {
    enum Kind { case move, resize }
    case began(Kind)
    case changed(Kind, CGSize)
    case ended
}

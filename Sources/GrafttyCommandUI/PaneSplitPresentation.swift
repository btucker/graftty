import GrafttyProtocol

public extension GhosttySplitDirection {
    /// SF Symbol whose filled inset half indicates where the newly-created
    /// pane will appear. Shared by Mac context menus and iPad toolbar buttons
    /// so opposite directions never collapse to the same axis-only glyph.
    var filledPaneSystemImageName: String {
        switch self {
        case .right:
            return "rectangle.righthalf.inset.filled"
        case .left:
            return "rectangle.leadinghalf.inset.filled"
        case .down:
            return "rectangle.bottomhalf.inset.filled"
        case .up:
            return "rectangle.tophalf.inset.filled"
        }
    }
}

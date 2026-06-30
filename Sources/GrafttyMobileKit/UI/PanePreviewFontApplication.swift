import CoreGraphics

/// @spec IOS-4.19
/// While a `PaneTile` already has a `TerminalController` whose font was
/// last sized from real authoritative grid columns, the application shall not
/// re-apply a font computed from the `PanePreviewFontSizing.defaultColumns`
/// fallback when the underlying `SessionClient` is replaced and its new
/// authoritative grid is briefly nil.
public enum PanePreviewFontApplication {
    public enum Decision: Equatable {
        case nothing
        case recreateController(fontSize: Float)
        case applyFont(Float)
    }

    public static func decide(
        tileWidth: CGFloat,
        authoritativeCols: UInt16?,
        hasController: Bool,
        sourceConfigMatches: Bool,
        lastAppliedFontSize: Float?
    ) -> Decision {
        let fontSize = PanePreviewFontSizing.fontSize(
            tileWidth: Double(tileWidth),
            authoritativeCols: authoritativeCols
        )
        let canUpdateInPlace = hasController && sourceConfigMatches
        if !canUpdateInPlace {
            return .recreateController(fontSize: fontSize)
        }
        if authoritativeCols == nil, lastAppliedFontSize != nil {
            return .nothing
        }
        if lastAppliedFontSize == fontSize {
            return .nothing
        }
        return .applyFont(fontSize)
    }
}

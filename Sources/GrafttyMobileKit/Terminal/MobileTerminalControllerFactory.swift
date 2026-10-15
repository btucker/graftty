import Foundation
import GhosttyTerminal

@MainActor
enum MobileTerminalControllerFactory {
    static func make(configText: String?) -> TerminalController {
        TerminalController(
            // Graftty owns link menus instead of a desktop hover bubble. Native
            // metadata is required to distinguish an OSC8 target from its label.
            configSource: .generated((configText ?? "") + "\nlink-previews = true\n"),
            theme: TerminalTheme()
        )
    }

    static func makePreview(configText: String, fontSize: Float) -> TerminalController {
        make(configText: appendingFontSizeOverride(
            to: configText,
            fontSize: fontSize
        ))
    }

    nonisolated static func appendingFontSizeOverride(
        to config: String,
        fontSize: Float,
        comment: String? = nil
    ) -> String {
        let formatted = String(format: "%g", Double(fontSize))
        let commentLine = comment.map { "# \($0)\n" } ?? ""
        return config + "\n\(commentLine)font-size = \(formatted)\n"
    }
}

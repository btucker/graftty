import Foundation
import GhosttyTerminal

@MainActor
enum MobileTerminalControllerFactory {
    static func make(configText: String?) -> TerminalController {
        TerminalController(
            configSource: configText.map { .generated($0) } ?? .none,
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

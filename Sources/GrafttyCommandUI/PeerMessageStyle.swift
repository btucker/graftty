import SwiftUI

/// Incoming agent identity, separate from human input and local agent progress.
enum PeerMessageStyle {
    /// Small sender labels need a darker purple on light reading backgrounds.
    static func color(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 0.78, green: 0.64, blue: 0.94, opacity: 1)
            : Color(.sRGB, red: 0.43, green: 0.18, blue: 0.64, opacity: 1)
    }
}

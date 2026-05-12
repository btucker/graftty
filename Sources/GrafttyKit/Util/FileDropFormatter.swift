import Foundation

/// @spec TERM-10.1
/// Lives in GrafttyKit (not on `SurfaceNSView`) so the rule is unit-testable
/// without an NSView host — same pattern as `SurfacePixelDimension.clamp`.
public enum FileDropFormatter {
    public static func format(paths: [String]) -> String {
        paths.map(shellQuote(_:)).joined(separator: " ")
    }

    /// `.alphanumerics` matches Unicode L*/N*, so the ASCII intersection
    /// is load-bearing — non-ASCII letters/digits in a filename should
    /// still get quoted.
    private static let safeCharacters: CharacterSet = CharacterSet(charactersIn: "/-_.,:@+%=")
        .union(.alphanumerics)
        .intersection(CharacterSet(charactersIn: UnicodeScalar(0x20)..<UnicodeScalar(0x7F)))

    private static func shellQuote(_ path: String) -> String {
        let scalars = path.unicodeScalars
        if !scalars.isEmpty, scalars.allSatisfy({ safeCharacters.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

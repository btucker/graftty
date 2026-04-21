import Foundation

/// Shared `IntegerFormatStyle<Int>` for rendering TCP port numbers into
/// UI surfaces — the Settings pane's Port TextField, status labels, any
/// future "current port" display. The default `.number` format is
/// locale-aware and emits a grouping separator (port 12345 renders
/// as "12,345" in en_US), which looks broken for a port and round-trips
/// fragilely back through `Int`'s parser. `noGrouping` is the single
/// point of truth so every port UI surface renders identically.
/// See `WEB-1.7`.
public enum WebPortFormat {
    public static let noGrouping: IntegerFormatStyle<Int> = .number.grouping(.never)
}

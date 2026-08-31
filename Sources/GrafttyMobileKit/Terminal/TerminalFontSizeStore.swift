#if canImport(UIKit)
import Foundation

enum TerminalFontSizeAdjustment {
    static let minimum: Float = 4
    static let maximum: Float = 64

    static func apply(steps: Int, to fontSize: Float) -> Float {
        min(max(fontSize + Float(steps), minimum), maximum)
    }
}

/// @spec IOS-6.21
/// When the user pinch-zooms an owner terminal, the application shall persist
/// the resulting font size by host and worktree path, use it as the live base
/// through ownership changes, and restore it for every terminal in that
/// worktree when the worktree is reopened.
///
/// The host is part of the key because identical absolute paths are common
/// across different Macs.
final class TerminalFontSizeStore: @unchecked Sendable {
    static let shared = TerminalFontSizeStore()

    private static let keyPrefix = "GrafttyMobile.terminalFontSize"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func fontSize(hostID: UUID, worktreePath: String) -> Float? {
        let key = defaultsKey(hostID: hostID, worktreePath: worktreePath)
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = Float(defaults.double(forKey: key))
        guard value.isFinite,
              value >= TerminalFontSizeAdjustment.minimum,
              value <= TerminalFontSizeAdjustment.maximum
        else { return nil }
        return value
    }

    func setFontSize(_ fontSize: Float, hostID: UUID, worktreePath: String) {
        guard fontSize.isFinite else { return }
        let value = TerminalFontSizeAdjustment.apply(steps: 0, to: fontSize)
        defaults.set(
            Double(value),
            forKey: defaultsKey(hostID: hostID, worktreePath: worktreePath)
        )
    }

    private func defaultsKey(hostID: UUID, worktreePath: String) -> String {
        let encodedPath = Data(worktreePath.utf8).base64EncodedString()
        return "\(Self.keyPrefix).\(hostID.uuidString).\(encodedPath)"
    }
}
#endif

import Foundation

/// Explicit control-bar bytes, independent of hardware-key translation.
enum TerminalTrayKey: Sendable {
    case tab, up, down, left, right

    func data(shift: Bool) -> Data {
        let suffix: String
        switch self {
        case .tab:
            return shift ? Data("\u{1B}[Z".utf8) : Data([0x09])
        case .up: suffix = "A"
        case .down: suffix = "B"
        case .left: suffix = "D"
        case .right: suffix = "C"
        }
        return Data("\u{1B}[\(shift ? "1;2" : "")\(suffix)".utf8)
    }
}

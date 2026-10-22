import Foundation
import GrafttyKit

/// Where the app finds the bundled `zmx` binary and keeps its sessions.
/// Panes, the web server and WebRTC host channels must all use the same
/// `ZMX_DIR`, or they would not see each other's sessions.
enum ZmxPaths {
    static let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zmx")
    static let directory = ZmxLauncher.defaultZmxDir
}

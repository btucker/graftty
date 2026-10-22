import Foundation

/// Where the app finds the bundled `zmx` binary and keeps its sessions.
/// Panes, the web server and WebRTC host channels must all use the same
/// `ZMX_DIR`, or they would not see each other's sessions.
enum ZmxPaths {
    static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zmx")
    }

    static var directory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Graftty", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
    }
}

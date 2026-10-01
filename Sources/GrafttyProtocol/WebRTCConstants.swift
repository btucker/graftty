import Foundation

/// Constants shared between the mobile-side `RemoteHostConnection` and
/// the Mac-side `WebRTCHostAgent`. Both sides must agree on these
/// values for the WebRTC connection to negotiate correctly.
public enum GrafttyWebRTC {
    /// The agreed-upon DataChannel label. The mobile side creates the
    /// channel with this label; the host side validates incoming
    /// channels match before adopting them.
    public static let dataChannelLabel: String = "graftty"

    /// Optional bulk transport, negotiated through an authenticated SSH probe.
    public static let bulkDataChannelLabel = "graftty-bulk-v1"
    public static let bulkSubsystem = "bulk-transport-v1@graftty.dev"
    public static let historySubsystemPrefix = "terminal-history-v1@graftty.dev/"
    public static let historyTokenEnvironment = "GRAFTTY_HISTORY_CHANNEL"

}

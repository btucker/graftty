import Foundation

/// Constants shared between the mobile-side `RemoteHostConnection` and
/// the Mac-side `WebRTCHostAgent`. Both sides must agree on these
/// values for the WebRTC connection to negotiate correctly.
public enum GrafttyWebRTC {
    /// The agreed-upon DataChannel label. The mobile side creates the
    /// channel with this label; the host side validates incoming
    /// channels match before adopting them.
    public static let dataChannelLabel: String = "graftty"
}

/// @spec REMOTE-9.26
/// The application shall advertise a 256 KiB maximum SSH channel packet size on host and client connections, so each channel's receive window is the 16 MiB that terminal flow control is sized for.
///
/// swift-nio-ssh sizes a channel's receive window at 64 times the maximum
/// packet size the connection advertises. Since 0.15 its default packet size
/// is 128 KiB, which halves the window that `TerminalSessionClient`'s receive
/// budget, `TerminalOutputCredit`, and the browser TCP bridge assume.
public enum SSHChannelWindow {
    /// The `maximumPacketSize` for every `SSHServerConfiguration` and
    /// `SSHClientConfiguration` Graftty creates.
    public static let maximumPacketSize = 1 << 18
    /// The receive window each SSH channel grants, in bytes.
    public static let receiveWindowBytes = 64 * maximumPacketSize
}

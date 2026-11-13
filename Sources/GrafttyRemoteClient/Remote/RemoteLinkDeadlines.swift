import Foundation

/// @spec REMOTE-11.29
/// The client shall allow thirty seconds for a signaling request to complete,
/// an SSH child channel to open, and a panes-state initial snapshot to arrive,
/// so a link with multi-second round trips is not torn down as stalled.
///
/// These deadlines detect a dead or wedged link, not a slow one. Satellite and
/// in-flight Wi-Fi routinely add one to several seconds of round-trip time
/// plus queueing behind bulk terminal output, and each of these exchanges
/// needs several round trips. Expiring one of them closes a feed or the whole
/// host transport, and reconnecting costs far more round trips than waiting.
public enum RemoteLinkDeadlines {
    /// One `/v2/rtc/challenge` or `/v2/rtc/offer` request, including the
    /// host's ICE gathering (up to five seconds) before it answers.
    public static let signalingRequest: TimeInterval = 30

    /// An SSH child channel open confirmation from the host. A paged terminal
    /// also allows this long for the host's reply to its subsystem request on
    /// the newly opened channel.
    public static let childChannelOpen: Duration = .seconds(30)

    /// The first panes-state snapshot after subsystem acceptance, including
    /// each renewal's channel open and subsystem negotiation.
    public static let firstSnapshot: Duration = .seconds(30)
}

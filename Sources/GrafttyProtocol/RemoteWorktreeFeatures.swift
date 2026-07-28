/// Capability advertisement used by Mobile's HTTP fallback.
///
/// Older Mobile builds do not understand relayed route identifiers, so the
/// Mac only appends one-hop repositories and worktrees when this token is
/// present. SSH capability negotiation covers the paired-device transport;
/// this header provides the equivalent guard for HTTP polling.
public enum RemoteWorktreeFeatures {
    public static let headerName = "X-Graftty-Features"
    public static let oneHopRelay = "remote-worktrees-v1"
}

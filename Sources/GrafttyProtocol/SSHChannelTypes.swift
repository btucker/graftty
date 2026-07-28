/// Wire-string identifiers for graftty's custom SSH channel types. These
/// strings are sent in `SSH_MSG_CHANNEL_OPEN` payloads and arrive on the
/// server side as `SSHChannelType.unknown(String)` per swift-nio-ssh.
///
/// The `@graftty.dev` suffix follows RFC 4254 §5.1's vendor-extension
/// convention; the channel types are namespaced and will not collide with
/// stock OpenSSH or other SSH libraries.
public enum SSHChannelTypeNames {
    /// Server-pushed snapshots of `[WorktreePanes]`. One channel per
    /// `RemoteHostConnection`.
    public static let panesState: String = "panes-state@graftty.dev"

    /// Origin-aware snapshots. Kept separate from the legacy channel so an
    /// older client can never mistake relayed aliases for local paths.
    public static let panesStateV2: String = "panes-state-v2@graftty.dev"

    /// Client→server RPC for splittree mutations (`split`, `close`,
    /// `swap`). One channel per connection; RPCs serialised by the client.
    public static let paneControl: String = "pane-control@graftty.dev"

    /// Repository discovery and create/delete/acknowledge RPCs.
    public static let worktreeManagement: String = "worktree-management@graftty.dev"
}

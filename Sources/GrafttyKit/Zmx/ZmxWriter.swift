import Foundation

/// @spec TEAM-IDLE-2.6
/// Test seam over the in-process zmx PTY-write path. Production
/// implementation calls into the same writer used by the existing
/// `zmx send` CLI subcommand (graftty owns the zmx integration —
/// no subprocess fork). Tests stub it to record invocations.
public protocol ZmxWriter: Sendable {
    func write(sessionName: String, text: String) async throws
}

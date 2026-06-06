// Inventory of unimplemented/untestable specs in the SYNC section.
// Promote entries to real @Tests before implementing the behavior.

import Testing

@Suite("SYNC — pending specs")
struct SyncTodo {
    @Test("""
@spec SYNC-5.1: While presence sharing is enabled for a repo, the sidebar shall render teammates' worktrees inside that repo's section with an owner badge and ambient styling.
""", .disabled("UI rendering; verified manually"))
    func sync_5_1() async throws { }
}

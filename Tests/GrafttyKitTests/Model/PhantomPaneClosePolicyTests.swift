import Testing
@testable import GrafttyKit

/// `TERM-5.7` blocks `closePane` when the pane's `SurfaceHandle` is missing,
/// to protect the preserved splitTree from a late `close_surface_cb`
/// cascade during Stop Worktree. But the same guard prevents the user
/// from removing a "phantom" leaf — a leaf whose surface never created
/// successfully (libghostty `OutOfMemory` / null return). Caught live
/// in cycle 80: libghostty refused 3 surfaces on restore, splitTree
/// still had those 3 leaves, `graftty pane close` reported OK (exit 0)
/// but the tree stayed at 3 leaves because the guard ate the mutation.
///
/// The fix splits the two scenarios:
/// - **User-initiated close** (`Cmd+W`, CLI `pane close`, context-menu
///   Close): always remove the leaf, even when the handle is missing —
///   that's exactly the case the user wants to fix.
/// - **libghostty-initiated close** (async `close_surface_cb`): keep the
///   TERM-5.7 guard so Stop cascades don't strip the preserved tree.
@Suite("TERM-5.8 — phantom-pane close policy")
struct PhantomPaneClosePolicyTests {
    @Test func userClosesLivePane() {
        #expect(PhantomPaneClosePolicy.shouldRemoveFromTree(
            userInitiated: true, handleExists: true
        ))
    }

    @Test func userClosesPhantomPane() {
        // This is the cycle-80 repro: surface never created, user wants
        // it gone. Must remove from tree.
        #expect(PhantomPaneClosePolicy.shouldRemoveFromTree(
            userInitiated: true, handleExists: false
        ))
    }

    @Test func libghosttyClosesLivePane() {
        // Normal shell-exit path (user types `exit` in the shell).
        #expect(PhantomPaneClosePolicy.shouldRemoveFromTree(
            userInitiated: false, handleExists: true
        ))
    }

    @Test func libghosttyCloseAfterTearDownIsSkipped() {
        // TERM-5.7 cascade protection: Stop tore down the handle, then a
        // late close_surface_cb arrived. Don't touch the tree.
        #expect(!PhantomPaneClosePolicy.shouldRemoveFromTree(
            userInitiated: false, handleExists: false
        ))
    }
}

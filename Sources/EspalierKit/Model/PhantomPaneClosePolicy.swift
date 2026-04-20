import Foundation

/// Pure policy for the `closePane` "should the leaf leave the tree?" decision
/// when a `SurfaceHandle` is missing.
///
/// Two scenarios share `handleExists == false` but mean opposite things:
///
/// 1. **`TERM-5.7` cascade.** `destroySurface` ran during a Stop, the handle
///    was removed, libghostty's async `close_surface_cb` arrives later.
///    splitTree was deliberately preserved (`TERM-1.2` / `prepareForStop`);
///    mutating it now would strip the preserved layout. **Don't remove.**
///
/// 2. **`TERM-5.8` phantom-leaf cleanup.** A leaf exists in splitTree but
///    its surface never instantiated successfully (libghostty returned
///    OOM / null via the failable `SurfaceHandle.init?`, protected by
///    `TERM-5.5`). The user reasonably wants to close it via Cmd+W /
///    CLI `pane close` / context menu. **Remove.**
///
/// The caller site distinguishes: user-initiated paths pass
/// `userInitiated: true`; libghostty-initiated paths pass `false`.
public enum PhantomPaneClosePolicy {
    public static func shouldRemoveFromTree(
        userInitiated: Bool,
        handleExists: Bool
    ) -> Bool {
        userInitiated || handleExists
    }
}

// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("ZMX — pending specs")
struct ZmxTodo {
    @Test("""
@spec ZMX-1.1: The application shall include a `zmx` binary in the app bundle at `Graftty.app/Contents/Helpers/zmx`, mirroring the placement of the `graftty` CLI.
""", .disabled("not yet implemented"))
    func zmx_1_1() async throws { }

    @Test("""
@spec ZMX-1.2: The bundled `zmx` binary shall be a universal Mach-O containing both `arm64` and `x86_64` slices, produced by `scripts/bump-zmx.sh`.
""", .disabled("not yet implemented"))
    func zmx_1_2() async throws { }

    @Test("""
@spec ZMX-1.3: The application shall pin the vendored `zmx` version in `Resources/zmx-binary/VERSION` and record its SHA256 in `Resources/zmx-binary/CHECKSUMS`.
""", .disabled("not yet implemented"))
    func zmx_1_3() async throws { }

    @Test("""
@spec ZMX-3.2: The application shall create the `ZMX_DIR` path if it does not exist at launch.
""", .disabled("not yet implemented"))
    func zmx_3_2() async throws { }

    @Test("""
@spec ZMX-4.2: When the application restores a worktree's split tree on launch (per `PERSIST-3.x`), each restored pane's surface shall be created with the same session name derived from the persisted pane UUID, so reattach to a surviving daemon is automatic.
""", .disabled("not yet implemented"))
    func zmx_4_2() async throws { }

    @Test("""
@spec ZMX-4.3: When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.
""", .disabled("not yet implemented"))
    func zmx_4_3() async throws { }

    @Test("""
@spec ZMX-5.1: If the bundled `zmx` binary is missing or not executable, the application shall fall back to libghostty's default `$SHELL` spawn behavior on a per-pane basis.
""", .disabled("not yet implemented"))
    func zmx_5_1() async throws { }

    @Test("""
@spec ZMX-5.2: If the bundled `zmx` binary is unavailable at launch, the application shall present a single non-blocking informational alert explaining that terminals will not survive app quit. The alert shall not be re-presented within the same process lifetime.
""", .disabled("not yet implemented"))
    func zmx_5_2() async throws { }

    @Test("""
@spec ZMX-6.1: Shell-integration OSC sequences (OSC 7 working directory, OSC 9 desktop notification, OSC 133 prompt marks, OSC 9;4 progress reports) shall continue to flow from the inner shell through `zmx` to libghostty unchanged. The `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` requirements remain in force regardless of whether `zmx` is mediating the PTY.
""", .disabled("not yet implemented"))
    func zmx_6_1() async throws { }

    @Test("""
@spec ZMX-7.1: When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.
""", .disabled("not yet implemented"))
    func zmx_7_1() async throws { }

    @Test("""
@spec ZMX-7.3: When `close_surface_cb` fires for a pane, the application shall always route to the close-pane path (remove from the split tree, free the surface) regardless of the zmx session's liveness. The mid-flight "rebuild surface in place" recovery explored in an earlier design was withdrawn because the available signals (session-missing + no Graftty-initiated close) cannot distinguish a clean user `exit` from an external daemon kill, and the rebuild path regressed `TERM-5.3`. Recovery from daemon loss while Graftty is running is deferred until a zmx-side signal disambiguates the two cases.
""", .disabled("not yet implemented"))
    func zmx_7_3() async throws { }

    @Test("""
@spec ZMX-8.1: The Settings → General pane shall expose a "Restart ZMX…" button that, after user confirmation, tears down every running pane across every worktree — invoking the same `destroySurface` / `zmx kill --force` path as per-worktree Stop (`TERM-1.2` / `ZMX-4.3`) — and then marks each affected worktree `.closed` via `prepareForStop` (`STATE-2.11`), preserving each worktree's `splitTree`, `focusedPaneSlotID`, and `primaryPaneSlotID` so re-opening recreates the same layout and startup ownership at the same leaf IDs under freshly-spawned zmx daemons. The confirmation alert (`NSAlert` with `.warning` style) shall name the destructive consequence explicitly — how many sessions across how many worktrees will end, with a "Any unsaved work in those sessions will be lost" warning (pluralization per `ZmxRestartConfirmation.informativeText`) — and shall offer "Restart ZMX" and "Cancel" buttons with Cancel as the default dismissal. If no worktrees are running at click time, the alert shall state that the action will have no effect rather than silently no-op.
""", .disabled("not yet implemented"))
    func zmx_8_1() async throws { }

}

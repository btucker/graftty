// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("PERSIST — pending specs")
struct PersistTodo {
    @Test("""
@spec PERSIST-1.1: The application shall store all persistent state in `~/Library/Application Support/Graftty/`.
""", .disabled("not yet implemented"))
    func persist_1_1() async throws { }

    @Test("""
@spec PERSIST-1.2: The application shall persist state to a `state.json` file containing: the ordered list of repositories and their worktrees, per-worktree split tree topology and `state` enum (`.closed`, `.running`, `.stale`), selected worktree, window frame, and sidebar width.
""", .disabled("not yet implemented"))
    func persist_1_2() async throws { }

    @Test("""
@spec PERSIST-2.1: The application shall save state when any of the following occur: split tree changes, worktree state changes, repository added or removed, selection changes, window resize or move (debounced), app moving to background, or app quit.
""", .disabled("not yet implemented"))
    func persist_2_1() async throws { }

    @Test("""
@spec PERSIST-2.2: When a state save fails (full disk, read-only `$HOME`, permissions clash, or any other `FileManager` / `Data.write` throw), the application shall log the error via `NSLog` so it surfaces in Console.app, rather than silently discarding every subsequent persisted mutation. Analogue of `ATTN-2.7` for the `AppState.save(to:)` path. `AppState.save(to:)` shall continue to throw so the caller can surface or recover; the spec pins only that the app-level caller stops using `try?` to mask it.
""", .disabled("not yet implemented"))
    func persist_2_2() async throws { }

    @Test("""
@spec PERSIST-3.1: When the application launches with an existing `state.json`, it shall restore the sidebar with all saved repositories and worktrees.
""", .disabled("not yet implemented"))
    func persist_3_1() async throws { }

    @Test("""
@spec PERSIST-3.2: When the application launches, it shall restore the saved split tree topology for each worktree.
""", .disabled("not yet implemented"))
    func persist_3_2() async throws { }

    @Test("""
@spec PERSIST-3.3: When the application launches, it shall automatically start fresh terminal surfaces for each worktree whose persisted `state` was `.running`.
""", .disabled("not yet implemented"))
    func persist_3_3() async throws { }

    @Test("""
@spec PERSIST-3.4: When the application launches, it shall restore the window frame position, size, and sidebar width.
""", .disabled("not yet implemented"))
    func persist_3_4() async throws { }

    @Test("""
@spec PERSIST-3.5: When the application launches, it shall re-select the previously selected worktree.
""", .disabled("not yet implemented"))
    func persist_3_5() async throws { }

    @Test("""
@spec PERSIST-3.6: When the application launches, it shall run worktree discovery for each repository to reconcile saved state against current disk state.
""", .disabled("not yet implemented"))
    func persist_3_6() async throws { }

    @Test("""
@spec PERSIST-3.7: If `state.json` exists but fails to decode at launch (corruption from a crashed mid-write, hand-edit typo, or schema mismatch across app versions), then the application shall move the file aside to a timestamped backup at `state.json.corrupt.<milliseconds-since-epoch>` and proceed with a fresh `AppState`. The corrupt file shall remain on disk so the user can recover the prior data manually; the application shall not silently overwrite it on the next save.
""", .disabled("not yet implemented"))
    func persist_3_7() async throws { }

    @Test("""
@spec PERSIST-4.1: The application shall not persist shell scrollback, terminal screen buffer content, or the specific processes that were running.
""", .disabled("not yet implemented"))
    func persist_4_1() async throws { }
}

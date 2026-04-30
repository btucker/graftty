// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("CONFIG — pending specs")
struct ConfigTodo {
    @Test("""
@spec CONFIG-1.1: At startup, the application shall call `ghostty_config_load_default_files` to load the XDG-standard ghostty config paths.
""", .disabled("not yet implemented"))
    func config_1_1() async throws { }

    @Test("""
@spec CONFIG-1.2: In addition to the XDG paths, the application shall load the Ghostty macOS app's config file at `~/Library/Application Support/com.mitchellh.ghostty/config` if the file exists. Values loaded later shall override earlier values.
""", .disabled("not yet implemented"))
    func config_1_2() async throws { }

    @Test("""
@spec CONFIG-1.3: After loading config files, the application shall call `ghostty_config_load_recursive_files` to resolve any `config-file = …` include directives.
""", .disabled("not yet implemented"))
    func config_1_3() async throws { }

    @Test("""
@spec CONFIG-2.1: Before calling `ghostty_init`, the application shall set the `GHOSTTY_RESOURCES_DIR` environment variable so libghostty can locate its per-shell integration scripts.
""", .disabled("not yet implemented"))
    func config_2_1() async throws { }

    @Test("""
@spec CONFIG-2.2: If `GHOSTTY_RESOURCES_DIR` is already set in the process environment, the application shall not override it; the user's explicit setting wins.
""", .disabled("not yet implemented"))
    func config_2_2() async throws { }

    @Test("""
@spec CONFIG-2.3: Otherwise, the application shall probe standard locations (`/Applications/Ghostty.app/Contents/Resources/ghostty` and `~/Applications/Ghostty.app/Contents/Resources/ghostty`) and, on first match, set `GHOSTTY_RESOURCES_DIR` to the match.
""", .disabled("not yet implemented"))
    func config_2_3() async throws { }

    @Test("""
@spec CONFIG-2.4: If no Ghostty.app installation is found, shell integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) shall silently be unavailable rather than surfacing an error; spawned shells shall still function.
""", .disabled("not yet implemented"))
    func config_2_4() async throws { }
}

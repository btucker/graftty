import Foundation

/// Pure helpers for deriving the sidebar pane label. The title pipeline
/// has three potential sources: the program-set OSC 2 title, the pane's
/// last-known working directory, and a static fallback. These functions
/// are the policy glue that decides which one renders.
public enum PaneTitle {

    /// Titles that are command-echo leaks from a shell-integration
    /// `preexec` hook. When the outer zsh runs Espalier's injected
    /// bootstrap line — `… GHOSTTY_ZSH_ZDOTDIR=… ZDOTDIR=… exec zmx attach …`
    /// — ghostty's preexec emits an OSC 2 whose payload IS that command.
    /// The inner shell spawned by `zmx attach` doesn't push a new title
    /// until the user's first prompt, so the leak sits in the sidebar
    /// until then. Rejecting these at intake keeps the leak out of the
    /// title store; the view falls back to the PWD basename.
    ///
    /// Two shapes to catch (`LAYOUT-2.13`):
    ///   1. **Pre-`ZMX-6.4` form**: starts with an uppercase identifier
    ///      followed by `=` (e.g. `GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR" …`).
    ///      Matched by `^[A-Z_][A-Z0-9_]*=`.
    ///   2. **Post-`ZMX-6.4` form**: starts with a shell conditional
    ///      (`if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR=…; fi; …`),
    ///      so the uppercase-prefix heuristic misses it. The whole line
    ///      still carries the literal `GHOSTTY_ZSH_ZDOTDIR` marker, which
    ///      no legitimate human-facing title would ever contain.
    ///
    /// False-positive risk: a program whose legitimate title starts with
    /// an uppercase identifier followed by `=` would also be filtered,
    /// or a title that incidentally names `GHOSTTY_ZSH_ZDOTDIR`.
    /// Human-facing titles almost never do either, so the trade is worth it.
    public static func isLikelyEnvAssignment(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Shape 2: the bootstrap string containing the GHOSTTY_ZSH_ZDOTDIR
        // marker. Catches both the post-ZMX-6.4 conditional form and any
        // future reshape that preserves the marker (guarding against a
        // recurrence of this exact bug class).
        if trimmed.contains("GHOSTTY_ZSH_ZDOTDIR") { return true }
        // Shape 1: uppercase-env-name prefix.
        guard let eq = trimmed.firstIndex(of: "=") else { return false }
        let name = trimmed[..<eq]
        guard !name.isEmpty else { return false }
        let first = name.first!
        guard first.isUppercase || first == "_" else { return false }
        return name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    /// Derive a short label from a pane's current working directory.
    /// Returns the directory's basename, or nil when `pwd` is empty, `/`,
    /// or unparseable. The caller renders the view-level "shell" fallback
    /// when this returns nil.
    public static func basenameLabel(pwd: String) -> String? {
        let trimmed = pwd.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        let stripped = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let last = (stripped as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// Choose the display title for a pane given the three signals in
    /// priority order: program-set title (already filtered at intake),
    /// PWD basename, and empty string (view draws "shell"). Kept as a
    /// single function so `SidebarView` and the CLI `listPanes` response
    /// agree on the rendered label.
    public static func display(storedTitle: String?, pwd: String?) -> String {
        if let t = storedTitle, !t.isEmpty { return t }
        if let pwd, let basename = basenameLabel(pwd: pwd) { return basename }
        return ""
    }
}

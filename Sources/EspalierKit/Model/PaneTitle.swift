import Foundation

/// Pure helpers for deriving the sidebar pane label. The title pipeline
/// has three potential sources: the program-set OSC 2 title, the pane's
/// last-known working directory, and a static fallback. These functions
/// are the policy glue that decides which one renders.
public enum PaneTitle {

    /// Titles matching `^[A-Z_][A-Z0-9_]*=` are the command-echo leak from
    /// a shell-integration `preexec` hook — when the outer zsh runs
    /// Espalier's injected `GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR" … exec zmx attach …`
    /// line, ghostty's preexec emits an OSC 2 whose first token is the
    /// env-assignment. The inner shell spawned by `zmx attach` doesn't
    /// push a new title until the user's first prompt, so the
    /// env-assignment stays visible in the sidebar until then. Rejecting
    /// these at intake keeps the leak out of our title store; the view
    /// can then fall back to the PWD basename.
    ///
    /// False-positive risk: a program whose legitimate title starts with
    /// an uppercase identifier followed by `=` would also be filtered.
    /// Human-facing titles almost never do that, so the trade is worth it.
    public static func isLikelyEnvAssignment(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
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

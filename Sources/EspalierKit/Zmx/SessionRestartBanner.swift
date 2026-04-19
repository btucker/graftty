import Foundation

/// Bytes Espalier prepends to a rebuilt pane's `initial_input` so the
/// user sees a visible marker that the underlying zmx session has been
/// replaced. Intended to be concatenated *before* the existing
/// `exec zmx attach …` line.
///
/// Shape: `printf '\n\033[2m— session restarted at HH:MM —\033[0m\n'\n`
///
/// We deliberately use `printf` (not `echo -e`, not `$(date …)`) for
/// portability — the outer shell that interprets this banner can be
/// bash, zsh, or fish, and only `printf` behaves identically across all
/// three. The timestamp is computed in Swift and embedded as a literal
/// so we do not need command substitution at all.
///
/// ANSI dim (`\033[2m`) + reset (`\033[0m`) wrap the message so it is
/// visually distinct from real shell output without being noisy.
public func sessionRestartBanner(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let stamp = formatter.string(from: date)
    return "printf '\\n\\033[2m— session restarted at \(stamp) —\\033[0m\\n'\n"
}

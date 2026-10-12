import Foundation

public enum LinuxHostComponent: String, CaseIterable, Sendable, Identifiable {
    case graftty, codex, claude
    public var id: String { rawValue }
    public var title: String {
        switch self { case .graftty: "Graftty"; case .codex: "Codex"; case .claude: "Claude Code" }
    }
}

/// Official native installers support Linux x86_64 and ARM64 without Node.
/// https://github.com/openai/codex and https://code.claude.com/docs/en/setup
enum LinuxHostToolScripts {
    static func install(_ component: LinuxHostComponent, onlyIfMissing: Bool = false, replaceCustom: Bool = false) -> String {
        precondition(component != .graftty)
        let name = component.rawValue
        let url = component == .codex ? "https://chatgpt.com/codex/install.sh" : "https://claude.ai/install.sh"
        let shell = component == .codex ? "/bin/sh" : "/bin/bash"
        let environment = component == .codex ? "CODEX_INSTALL_DIR=\"$HOME/.local/bin\" " : ""
        let nativeRoot = component == .codex ? "${CODEX_HOME:-$HOME/.codex}/packages/standalone" : "$HOME/.local/share/claude/versions"
        let existing = """
        existing=$(command -v \(name) || true)
        if test -n "$existing"; then
          target=$(readlink -f -- "$existing")
          native_root=$(readlink -m -- "\(nativeRoot)")
          case "$target" in
            "$native_root"/*)
              \(component == .claude ? "timeout --kill-after=5 300 \"$existing\" update\ntimeout --kill-after=1 15 \"$existing\" --version\nexit 0" : ":") ;;
            *) \(replaceCustom ? ": # Explicitly selected replacement" : "echo 'Existing \(name) is a custom or package-managed install. Select Replace custom installation to install the native tool in ~/.local/bin, or update it with its package manager.' >&2; exit 75") ;;
          esac
        fi
        """
        return """
        set -eu
        export PATH="$HOME/.local/bin:$PATH"
        \(onlyIfMissing ? "if command -v \(name) >/dev/null 2>&1; then timeout --kill-after=1 15 \(name) --version; exit 0; fi" : "")
        \(component == .claude ? "test \"${DISABLE_UPDATES:-}\" != 1 && test \"${DISABLE_UPDATES:-}\" != true || { echo 'Claude updates are disabled by DISABLE_UPDATES' >&2; exit 75; }" : "")
        \(existing)
        command -v curl >/dev/null 2>&1 || { echo 'Install curl on the Linux host first' >&2; exit 70; }
        umask 077
        tool_stage=$(mktemp -d)
        trap 'rm -rf -- "$tool_stage"' EXIT
        trap 'exit 130' HUP INT TERM
        curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 --output "$tool_stage/install.sh" \(LinuxHostScripts.quote(url))
        \(environment)timeout --kill-after=5 300 \(shell) "$tool_stage/install.sh"
        timeout --kill-after=1 15 "$HOME/.local/bin/\(name)" --version
        """
    }
}

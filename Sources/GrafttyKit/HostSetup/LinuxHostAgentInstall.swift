import Foundation

extension LinuxHostScripts {
    /// Keep discovery in the user's interactive login environment, without
    /// allowing profile output to become PATH or installer output to become JSON.
    static func ensureAgentCLI(provider: TeamHookRuntime, staging: String) -> String {
        let name = provider.rawValue
        let url: String
        let invocation: String
        switch provider {
        case .claude:
            url = "https://claude.ai/install.sh"
            invocation = "/bin/bash \"$agent_work/installer\" stable"
        case .codex:
            url = "https://chatgpt.com/codex/install.sh"
            invocation = "/usr/bin/env CODEX_NON_INTERACTIVE=true CODEX_INSTALL_DIR=\"$HOME/.local/bin\" /bin/sh \"$agent_work/installer\""
        }
        return """
        (
        set -eu
        umask 077
        agent_fail() {
          echo \(quote("GRAFTTY_AGENT_INSTALL:\(name):")) "$1" >&2
          if test "$#" -gt 1 && test -n "${agent_tail:-}" && test -f "$2"; then
            "$agent_tail" -c 8192 "$2" | "$agent_tail" -n 20 >&2 || true
          fi
          echo \(quote("Fix the \(name) setup problem on the Linux host, then retry setup.")) >&2
          exit 75
        }
        agent_tail=$(command -v tail) || agent_fail 'The tail utility is missing.'
        agent_timeout=$(command -v timeout) || agent_fail 'The timeout utility is missing.'
        agent_flock=$(command -v flock) || agent_fail 'The flock utility is missing.'
        agent_data=${XDG_DATA_HOME:-$HOME/.local/share}
        case "$agent_data" in /*) ;; *) agent_fail 'XDG_DATA_HOME must be an absolute path.';; esac
        mkdir -p "$agent_data/graftty" || agent_fail 'Could not create the per-user installer lock directory.'
        exec 9> "$agent_data/graftty/agent-install.lock"
        "$agent_flock" -w 30 9 || agent_fail 'Another agent installation is still running; wait for it to finish.'
        agent_work=$(mktemp -d \(quote(staging + "/agent-" + name + ".XXXXXX"))) || agent_fail 'Could not create private installer files.'
        trap 'rm -rf -- "$agent_work"' EXIT
        agent_path_file="$agent_work/login-path"
        # Child daemons must not retain the installer lock after this shell exits.
        if ! GRAFTTY_AGENT_PATH_FILE="$agent_path_file" "$agent_timeout" --kill-after=1 15 "${SHELL:-/bin/bash}" -ilc '/usr/bin/printenv PATH > "$GRAFTTY_AGENT_PATH_FILE"' > "$agent_work/profile.log" 2>&1 < /dev/null 9>&-; then
          agent_fail 'Could not read PATH from the interactive login shell within 15 seconds. Check shell startup files.'
        fi
        test -s "$agent_path_file" || agent_fail 'The interactive login shell did not report PATH. Check shell startup files.'
        agent_path=$(cat "$agent_path_file") || agent_fail 'Could not read the login shell PATH.'
        test -n "$agent_path" || agent_fail 'The interactive login shell reported an empty PATH.'
        PATH="$agent_path:$HOME/.local/bin"
        export PATH
        agent_verify() {
          agent_executable=$(command -v \(quote(name))) || agent_fail 'The installer finished but the executable is still missing from PATH.'
          test -f "$agent_executable" && test -x "$agent_executable" || agent_fail 'PATH resolves to a non-executable entry; repair it before retrying.'
          "$agent_timeout" --kill-after=1 15 "$agent_executable" --version > "$agent_work/version.log" 2>&1 < /dev/null 9>&- || agent_fail 'The executable failed --version or timed out. Repair it before retrying.' "$agent_work/version.log"
        }
        if command -v \(quote(name)) >/dev/null 2>&1; then
          agent_verify
        else
          command -v curl >/dev/null 2>&1 || agent_fail 'curl is required to download the official installer.'
          curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 --output "$agent_work/installer" \(quote(url)) > "$agent_work/download.log" 2>&1 || agent_fail 'Downloading the official installer failed or timed out.' "$agent_work/download.log"
          # Let the official installer detect and persist a missing PATH entry.
          PATH="$agent_path" "$agent_timeout" --kill-after=1 300 \(invocation) > "$agent_work/install.log" 2>&1 < /dev/null 9>&- || agent_fail 'The official installer failed or exceeded five minutes.' "$agent_work/install.log"
          hash -r
          agent_verify
        fi
        )
        """
    }
}

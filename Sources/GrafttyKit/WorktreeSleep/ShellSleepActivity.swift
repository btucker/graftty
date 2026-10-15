import Foundation

/// An owned ZLE input boundary distinguishes an idle prompt from a quiet
/// builtin command. Unsupported shells and missing evidence stay awake.
public enum ShellSleepActivity {
    public static func file(directory: URL, session: String) -> URL {
        directory.appendingPathComponent(session + ".sleep-state")
    }

    public static func isAtPrompt(file: URL, identity: SleepProcessIdentity, minimumBoundary: TimeInterval = 0) -> Bool {
        guard FileManager.default.isWritableFile(atPath: file.path),
              FileManager.default.isWritableFile(atPath: file.deletingLastPathComponent().path),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, Int32(fields[0]) == identity.pid, fields[1] == "prompt",
              let boundary = Double(fields[2]), boundary.isFinite,
              boundary >= Double(identity.startTime) / 1_000_000,
              boundary >= minimumBoundary,
              boundary <= Date().timeIntervalSince1970 + 1 else { return false }
        return true
    }

    public static let zshHooks = #"""
    if [[ -n ${GRAFTTY_SLEEP_STATE_FILE-} ]] && zmodload zsh/datetime && zmodload zsh/zleparameter; then
        autoload -Uz add-zle-hook-widget
        _graftty_sleep_write() {
            builtin print -r -- "$$ $1 $EPOCHREALTIME" >| "$GRAFTTY_SLEEP_STATE_FILE" 2>/dev/null ||
                command rm -f -- "$GRAFTTY_SLEEP_STATE_FILE" 2>/dev/null
            return 0
        }
        _graftty_sleep_busy() { _graftty_sleep_write busy }
        _graftty_sleep_prompt() {
            emulate -L zsh
            local callbacks scheduled widget registration
            [[ ${CONTEXT-} == start ]] || { _graftty_sleep_write unknown; return }
            callbacks=$(builtin zle -F 2>/dev/null) || { _graftty_sleep_write unknown; return }
            scheduled=$(builtin sched 2>/dev/null) || { _graftty_sleep_write unknown; return }
            if [[ -n $callbacks || -n $scheduled || -n ${functions[periodic]-} ||
                  ( -n ${TMOUT-} && ${TMOUT} != 0 ) || -n ${(k)functions[(I)TRAP*]} ]]; then
                _graftty_sleep_write unknown
                return
            fi
            # List-form traps reset in subshells, so inventory the parent.
            builtin trap >| "$GRAFTTY_SLEEP_STATE_FILE.traps" 2>/dev/null || { _graftty_sleep_write unknown; return }
            while IFS= read -r registration; do
                [[ $registration == "trap -- '' "* ]] || { _graftty_sleep_write unknown; return }
            done < "$GRAFTTY_SLEEP_STATE_FILE.traps"
            # The exact default registrations contain no shell callbacks.
            builtin compctl -L >| "$GRAFTTY_SLEEP_STATE_FILE.completion" 2>/dev/null || { _graftty_sleep_write unknown; return }
            while IFS= read -r registration; do
                case $registration in
                    'compctl -C -c -tn'|'compctl -D -f -tn'|'compctl -T') ;;
                    *) _graftty_sleep_write unknown; return ;;
                esac
            done < "$GRAFTTY_SLEEP_STATE_FILE.completion"
            # User widgets can run quiet builtin jobs while ZLE remains active.
            # Only these owned lifecycle/control widgets are certified here.
            for widget in ${(k)widgets}; do
                case ${widgets[$widget]} in
                    builtin) ;;
                    user:_graftty_sleep_prompt|user:_graftty_sleep_busy|user:azhw:zle-line-init|user:azhw:zle-line-finish|\
                    user:_ghostty_zle_line_init|user:_ghostty_zle_line_finish|user:_ghostty_zle_keymap_select) ;;
                    *) _graftty_sleep_write unknown; return ;;
                esac
            done
            _graftty_sleep_write prompt
        }
        _graftty_sleep_arm() {
            emulate -L zsh
            _graftty_sleep_busy
            add-zle-hook-widget -d line-init _graftty_sleep_prompt
            add-zle-hook-widget line-init _graftty_sleep_prompt || return
            add-zle-hook-widget line-finish _graftty_sleep_busy || return
            # Invalidate before any existing finish callback can run a job.
            local -a existing ordered
            local hook
            local index=0
            zstyle -a zle-line-finish widgets existing
            for hook in ${(on)existing}; do
                hook=${hook#<->:}
                [[ $hook == _graftty_sleep_busy ]] && continue
                (( ++index ))
                ordered+=("$index:$hook")
            done
            zstyle zle-line-finish widgets "0:_graftty_sleep_busy" "${ordered[@]}"
        }
        typeset -ga preexec_functions precmd_functions
        preexec_functions=(_graftty_sleep_busy ${preexec_functions:#_graftty_sleep_busy})
        precmd_functions=(${precmd_functions:#_graftty_sleep_arm} _graftty_sleep_arm)
        _graftty_sleep_busy
    fi
    """#
}

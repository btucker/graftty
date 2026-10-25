import Foundation
@testable import GrafttyKit

/// A frozen copy of `AgentHookInstaller.codexWrapperScript` as it was built
/// from Swift string literals before the wrapper moved to
/// `Teams/Resources/codex-wrapper.sh`, with deliberate #533 corrections for
/// path quoting, the durable-home default, and missing lockf fallback.
/// `CodexWrapperTemplateTests` proves the template matches those reviewed
/// bytes; delete this file and those tests once the template has shipped.
enum LegacyCodexWrapperScript {
    static func render(
        wrapperDirectory: String,
        grafttyCLIPath: String,
        codexHomeDirectory: String,
        codexSourceDirectory: String,
        codexLockCommandPath: String
    ) -> String {
        let runtime = TeamHookRuntime.codex
        #if os(macOS)
        let launcher = shellLiteral((wrapperDirectory as NSString).appendingPathComponent("codex-browser-tui"))
        let tuiCommand = """
        if [ -x \(launcher) ]; then
          env CODEX_HOME="$_graftty_codex_runtime_home" \(launcher) "$_graftty_codex_native_binary" "$real_binary" --enable hooks --remote "unix://$_graftty_codex_socket" "$@"
        else
          env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks --remote "unix://$_graftty_codex_socket" "$@"
        fi
        """
        #else
        let tuiCommand = "env CODEX_HOME=\"$_graftty_codex_runtime_home\" \"$real_binary\" --enable hooks --remote \"unix://$_graftty_codex_socket\" \"$@\""
        #endif
        let resolveBlock = realBinaryResolutionShell(
            wrapperDirectory: wrapperDirectory,
            realCommandName: runtime.rawValue
        )
        let registerBlock = """
        # Register this wrapper PID before launching the runtime. The runtime
        # remains a foreground child in the same process group so TUIs keep
        # normal terminal semantics, while the wrapper gets a short teardown
        # phase after the runtime exits.
        _graftty_agent_suffix="$(uuidgen 2>/dev/null | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)"
        if [ "${#_graftty_agent_suffix}" -ne 12 ]; then
          _graftty_agent_suffix="$(printf '%012x' "$$")"
        fi
        GRAFTTY_AGENT_ID="\(runtime.rawValue)-$_graftty_agent_suffix"
        export GRAFTTY_AGENT_ID
        unset _graftty_agent_suffix
        \(shellLiteral(grafttyCLIPath)) team register --runtime \(runtime.rawValue) --pid "$$" >/dev/null 2>&1 || true
        """

        let codexCleanupBlock = """
              if [ -n "${_graftty_codex_socket:-}" ] && [ -n "${_graftty_codex_app_server_pid:-}" ]; then
                \(shellLiteral(grafttyCLIPath)) team codex-app-server unregister --socket "$_graftty_codex_socket" --app-server-pid "$_graftty_codex_app_server_pid" >/dev/null 2>&1 || true
              fi
              if [ -n "${_graftty_codex_app_server_pid:-}" ]; then
                kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
                _graftty_codex_shutdown_wait_count=0
                while kill -0 "$_graftty_codex_app_server_pid" 2>/dev/null; do
                  if [ "$_graftty_codex_shutdown_wait_count" -ge 20 ]; then
                    kill -KILL "$_graftty_codex_app_server_pid" 2>/dev/null || true
                    break
                  fi
                  sleep 0.1
                  _graftty_codex_shutdown_wait_count=$((_graftty_codex_shutdown_wait_count + 1))
                done
                wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
                unset _graftty_codex_shutdown_wait_count
              fi
              if [ -n "${_graftty_codex_socket:-}" ]; then
                rm -f "$_graftty_codex_socket"
              fi
              if [ -z "${_graftty_preserve_codex_app_server_log:-}" ] && [ -n "${_graftty_codex_app_server_log:-}" ]; then
                rm -f "$_graftty_codex_app_server_log"
              fi
            """

        let cleanupBlock = """
        cleanup_after_runtime() {
          # Some TUIs issue terminal capability queries during startup/shutdown.
          # A late reply can otherwise land in the parent shell after the TUI
          # exits (for example Kitty keyboard protocol replies like CSI ? ... u).
          # Drain only a tiny, immediately-pending window and restore tty state.
          if [ -t 0 ] && command -v stty >/dev/null 2>&1 && command -v dd >/dev/null 2>&1; then
            _graftty_stty="$(stty -g 2>/dev/null)" || _graftty_stty=""
            if [ -n "$_graftty_stty" ] && stty -icanon -echo min 0 time 1 2>/dev/null; then
              dd bs=1024 count=1 of=/dev/null 2>/dev/null || true
              stty "$_graftty_stty" 2>/dev/null || true
            fi
          fi
          \(shellLiteral(grafttyCLIPath)) team unregister --runtime \(runtime.rawValue) 2>/dev/null || true
        \(codexCleanupBlock)
        }
        """

        let codexHomeLiteral = shellLiteral(codexHomeDirectory)
        let codexSourceLiteral = shellLiteral(codexSourceDirectory)
        let codexLockLiteral = shellLiteral(
            URL(fileURLWithPath: codexHomeDirectory)
                .appendingPathComponent(".graftty-mirror.lock")
                .path
        )
        let runtimeBlock = """
        _graftty_codex_sync_status=0
        _graftty_codex_runtime_home=\(codexHomeLiteral)
          _graftty_codex_should_use_app_server() {
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --help|-h|--version|-V)
                  return 1
                  ;;
                --remote|--remote=*)
                  return 1
                  ;;
                -i|--image)
                  shift
                  while [ "$#" -gt 0 ]; do
                    case "$1" in
                      --)
                        return 0
                        ;;
                      --help|-h|--version|-V|--remote|--remote=*)
                        return 1
                        ;;
                    esac
                    shift
                  done
                  return 0
                  ;;
                -c|--config|--enable|--disable|--model|-m|--profile|-p|--sandbox|-s|--ask-for-approval|-a|--approval-policy|--cwd|--cd|-C|--color|--output-schema|--origin|--settings|--remote-auth-token-env|--local-provider|--add-dir)
                  shift
                  [ "$#" -gt 0 ] && shift
                  continue
                  ;;
                --)
                  return 0
                  ;;
                -*)
                  shift
                  continue
                  ;;
                app-server|remote-control|exec|e|review|login|logout|mcp|plugin|mcp-server|app|completion|update|doctor|sandbox|debug|apply|a|archive|delete|unarchive|cloud|exec-server|features|help)
                  return 1
                  ;;
                *)
                  return 0
                  ;;
              esac
            done
            return 0
          }
          _graftty_codex_requests_help() {
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --)
                  return 1
                  ;;
                --help|-h|--version|-V)
                  return 0
                  ;;
              esac
              shift
            done
            return 1
          }
          _graftty_codex_uses_durable_home() {
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --help|-h|--version|-V|--)
                  return 1
                  ;;
                -i|--image)
                  return 1
                  ;;
                -c|--config|--enable|--disable|--model|-m|--profile|-p|--sandbox|-s|--ask-for-approval|-a|--approval-policy|--cwd|--cd|-C|--color|--output-schema|--origin|--settings|--remote-auth-token-env|--local-provider|--add-dir)
                  shift
                  [ "$#" -gt 0 ] && shift
                  ;;
                --config=*|--enable=*|--disable=*|--model=*|--profile=*|--sandbox=*|--ask-for-approval=*|--approval-policy=*|--cwd=*|--cd=*|--color=*|--output-schema=*|--origin=*|--settings=*|--remote-auth-token-env=*|--local-provider=*|--add-dir=*|--image=*)
                  shift
                  ;;
                login|logout|plugin|mcp|features)
                  return 0
                  ;;
                -*)
                  shift
                  ;;
                *)
                  return 1
                  ;;
              esac
            done
            return 1
          }
          _graftty_codex_configuration_changed() {
            if _graftty_codex_requests_help "$@"; then
              return 1
            fi
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -i|--image)
                  return 1
                  ;;
                -c|--config|--enable|--disable|--model|-m|--profile|-p|--sandbox|-s|--ask-for-approval|-a|--approval-policy|--cwd|--cd|-C|--color|--output-schema|--origin|--settings|--remote-auth-token-env|--local-provider|--add-dir)
                  shift
                  [ "$#" -gt 0 ] && shift
                  ;;
                --config=*|--enable=*|--disable=*|--model=*|--profile=*|--sandbox=*|--ask-for-approval=*|--approval-policy=*|--cwd=*|--cd=*|--color=*|--output-schema=*|--origin=*|--settings=*|--remote-auth-token-env=*|--local-provider=*|--add-dir=*|--image=*)
                  shift
                  ;;
                plugin)
                  shift
                  while [ "$#" -gt 0 ]; do
                    case "$1" in
                      -c|--config|--enable|--disable)
                        shift
                        [ "$#" -gt 0 ] && shift
                        ;;
                      --config=*|--enable=*|--disable=*)
                        shift
                        ;;
                      *)
                        break
                        ;;
                    esac
                  done
                  case "${1:-}" in
                    add|remove)
                      return 0
                      ;;
                    marketplace)
                      shift
                      while [ "$#" -gt 0 ]; do
                        case "$1" in
                          -c|--config|--enable|--disable)
                            shift
                            [ "$#" -gt 0 ] && shift
                            ;;
                          --config=*|--enable=*|--disable=*)
                            shift
                            ;;
                          *)
                            break
                            ;;
                        esac
                      done
                      case "${1:-}" in
                        add|remove|upgrade)
                          return 0
                          ;;
                      esac
                      ;;
                  esac
                  return 1
                  ;;
                mcp)
                  shift
                  while [ "$#" -gt 0 ]; do
                    case "$1" in
                      -c|--config|--enable|--disable)
                        shift
                        [ "$#" -gt 0 ] && shift
                        ;;
                      --config=*|--enable=*|--disable=*)
                        shift
                        ;;
                      *)
                        break
                        ;;
                    esac
                  done
                  case "${1:-}" in
                    add|remove|login|logout)
                      return 0
                      ;;
                  esac
                  return 1
                  ;;
                features)
                  shift
                  while [ "$#" -gt 0 ]; do
                    case "$1" in
                      -c|--config|--enable|--disable)
                        shift
                        [ "$#" -gt 0 ] && shift
                        ;;
                      --config=*|--enable=*|--disable=*)
                        shift
                        ;;
                      *)
                        break
                        ;;
                    esac
                  done
                  case "${1:-}" in
                    enable|disable)
                      return 0
                      ;;
                  esac
                  return 1
                  ;;
                --)
                  return 1
                  ;;
                -*)
                  shift
                  ;;
                *)
                  return 1
                  ;;
              esac
            done
            return 1
          }
          _graftty_codex_run_administration() (
            _graftty_codex_admin_home=$1
            shift
            if [ "$_graftty_codex_admin_home" = \(codexSourceLiteral) ] &&
               [ -f \(codexLockLiteral) ] &&
               [ -r \(codexLockLiteral) ]; then
              exec 9<\(codexLockLiteral) || exit $?
              if command -v \(shellLiteral(codexLockCommandPath)) >/dev/null 2>&1; then
                \(shellLiteral(codexLockCommandPath)) -s 9
              else
                flock -x 9
              fi
              _graftty_codex_lock_status=$?
              if [ "$_graftty_codex_lock_status" -ge 128 ]; then
                exit "$_graftty_codex_lock_status"
              elif [ "$_graftty_codex_lock_status" -ne 0 ]; then
                printf '%s\\n' "graftty: could not lock the managed Codex home; continuing durable administration without rebuild coordination" >&2
                exec 9<&-
              fi
            fi
            env CODEX_HOME="$_graftty_codex_admin_home" "$real_binary" "$@"
          )
          if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
          if [ "${CODEX_HOME:-}" != \(codexHomeLiteral) ]; then
            \(shellLiteral(grafttyCLIPath)) internal sync-codex-home || _graftty_codex_sync_status=$?
          fi
          if [ "$_graftty_codex_sync_status" -ne 0 ]; then
            _graftty_codex_runtime_home=\(codexSourceLiteral)
            printf '%s\\n' "graftty: could not prepare the managed Codex home; starting with the durable Codex home instead" >&2
          fi
          if _graftty_codex_uses_durable_home "$@"; then
            _graftty_codex_run_administration \(codexSourceLiteral) "$@"
            _graftty_codex_command_status=$?
            if [ "$_graftty_codex_command_status" -eq 0 ] && _graftty_codex_configuration_changed "$@"; then
              printf '%s\\n' "graftty: reload the agent or start a new session for Codex configuration changes to take effect" >&2
            fi
            (exit "$_graftty_codex_command_status")
          elif ! _graftty_codex_should_use_app_server "$@"; then
            env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks "$@"
          else
          _graftty_codex_native_binary="$(\(shellLiteral(grafttyCLIPath)) team codex-app-server resolve-binary --real-binary "$real_binary" 2>/dev/null)"
          if [ ! -x "$_graftty_codex_native_binary" ]; then
            _graftty_codex_native_binary="$real_binary"
          fi
          _graftty_codex_socket_dir="${TMPDIR:-/tmp}/graftty-codex-app-server"
          mkdir -p "$_graftty_codex_socket_dir"
          _graftty_codex_socket="$_graftty_codex_socket_dir/$$.sock"
          _graftty_codex_app_server_log="$_graftty_codex_socket_dir/$$.log"
          rm -f "$_graftty_codex_socket" "$_graftty_codex_app_server_log"
          env CODEX_HOME="$_graftty_codex_runtime_home" "$_graftty_codex_native_binary" --enable hooks app-server --listen "unix://$_graftty_codex_socket" </dev/null >>"$_graftty_codex_app_server_log" 2>&1 &
          _graftty_codex_app_server_pid=$!
          _graftty_wait_for_codex_socket() {
            _graftty_wait_count=0
            while [ "$_graftty_wait_count" -lt 50 ]; do
              if [ -S "$_graftty_codex_socket" ]; then
                return 0
              fi
              if ! kill -0 "$_graftty_codex_app_server_pid" 2>/dev/null; then
                return 1
              fi
              sleep 0.1
              _graftty_wait_count=$((_graftty_wait_count + 1))
            done
            return 1
          }
          if ! _graftty_wait_for_codex_socket; then
            printf '%s\\n' "graftty: codex app-server failed to start; see $_graftty_codex_app_server_log" >&2
            kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
            wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
            rm -f "$_graftty_codex_socket"
            _graftty_preserve_codex_app_server_log=1
            cleanup_after_runtime
            exit 1
          fi
          \(shellLiteral(grafttyCLIPath)) team codex-app-server register --socket "$_graftty_codex_socket" --real-binary "$_graftty_codex_native_binary" --app-server-pid "$_graftty_codex_app_server_pid" --owner-pid "$$" >/dev/null 2>&1 || true
          \(tuiCommand)
          _graftty_codex_tui_status=$?
          if [ "$_graftty_codex_tui_status" -ne 0 ]; then
            _graftty_preserve_codex_app_server_log=1
            printf '%s\\n' "graftty: codex exited with status $_graftty_codex_tui_status; app-server log: $_graftty_codex_app_server_log" >&2
          fi
          (exit "$_graftty_codex_tui_status")
          fi
        else
          if _graftty_codex_uses_durable_home "$@"; then
            _graftty_codex_admin_home="${CODEX_HOME:-}"
            if [ -z "$_graftty_codex_admin_home" ] || [ "$_graftty_codex_admin_home" = \(codexHomeLiteral) ]; then
              _graftty_codex_admin_home=\(codexSourceLiteral)
            fi
            _graftty_codex_run_administration "$_graftty_codex_admin_home" "$@"
            _graftty_codex_command_status=$?
            if [ "$_graftty_codex_command_status" -eq 0 ] && _graftty_codex_configuration_changed "$@"; then
              printf '%s\\n' "graftty: reload the agent or start a new session for Codex configuration changes to take effect" >&2
            fi
            (exit "$_graftty_codex_command_status")
          else
            "$real_binary" "$@"
          fi
        fi
        """

        return """
        #!/bin/sh
        # GRAFTTY_AGENT_HOOK_WRAPPER version=\(AgentHookInstaller.version)
        # Hooks run: graftty team hook \(runtime.rawValue)
        \(resolveBlock)

        \(registerBlock)

        \(cleanupBlock)

        \(runtimeBlock)
        runtime_status=$?
        cleanup_after_runtime
        exit "$runtime_status"
        """
    }

    private static func realBinaryResolutionShell(wrapperDirectory: String, realCommandName: String) -> String {
        """
        real_binary=""
        old_ifs="$IFS"
        IFS=":"
        for dir in $PATH; do
          if [ "$dir" = \(shellLiteral(wrapperDirectory)) ]; then
            continue
          fi
          if [ -x "$dir/\(realCommandName)" ]; then
            real_binary="$dir/\(realCommandName)"
            break
          fi
        done
        IFS="$old_ifs"

        if [ -z "$real_binary" ]; then
          printf '%s\\n' \(shellLiteral("graftty: unable to find real \(realCommandName) outside \(wrapperDirectory)")) >&2
          exit 127
        fi
        """
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

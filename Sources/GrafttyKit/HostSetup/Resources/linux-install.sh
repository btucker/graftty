#!/usr/bin/env bash
set -euo pipefail
# Installs for the invoking user. No sudo or system-wide service is needed.
usage() {
    echo 'Usage: ./install.sh [--bind-address ADDRESS] [--ssh-port PORT] [--http-port PORT] [--no-start] [--maintenance]'
}
bind_address=127.0.0.1
ssh_port=8801
http_port=8800
start_service=1
maintenance=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bind-address|--ssh-port|--http-port)
            [[ $# -ge 2 ]] || { usage >&2; exit 64; }
            case "$1" in
                --bind-address) bind_address=$2 ;;
                --ssh-port) ssh_port=$2 ;;
                --http-port) http_port=$2 ;;
            esac
            shift 2 ;;
        --no-start) start_service=0; shift ;;
        --maintenance) maintenance=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done
[[ $bind_address =~ ^[a-zA-Z0-9_.:%-]+$ ]] || { echo 'Invalid bind address' >&2; exit 64; }
for port in "$ssh_port" "$http_port"; do
    if [[ ! $port =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        echo 'Invalid port' >&2
        exit 64
    fi
done
ssh_port=$((10#$ssh_port))
http_port=$((10#$http_port))
[[ $ssh_port != "$http_port" ]] || { echo 'HTTP and SSH ports must differ' >&2; exit 64; }
source_dir=$(cd "$(dirname "$(readlink -f -- "$0")")" && pwd)
[[ -n ${HOME:-} && $HOME == /* ]] || { echo 'HOME must be an absolute path' >&2; exit 1; }
version=$(cat "$source_dir/VERSION")
[[ $version =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || { echo 'Invalid archive version' >&2; exit 1; }
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
[[ $data_home == /* && $config_home == /* ]] || { echo 'XDG directories must be absolute paths' >&2; exit 1; }
release="$data_home/graftty/releases/$version"
# systemd expands percent specifiers and rejects newlines in command arguments.
for path in "$release" "$HOME/.local/bin" "$config_home"; do
    [[ $path != *$'\n'* && $path != *$'\r'* && $path != *'%'* ]] || { echo 'Unsupported install path' >&2; exit 1; }
done
mkdir -p "$data_home/graftty/releases" "$HOME/.local/bin" "$config_home/systemd/user"
# Every install changes this user's command links, even with a custom XDG
# directory. Keep the lock until EXIT cleanup has completed any rollback.
exec 9>"$HOME/.local/bin/.graftty-install.lock"
flock 9
if ((maintenance)) && [[ -n ${GRAFTTY_MAINTENANCE_PREFLIGHT_FILE:-} ]]; then
    # Downloads and other installers may run before this lock. Bind the
    # identity and reviewed version again before any service/release changes.
    /bin/sh "$GRAFTTY_MAINTENANCE_PREFLIGHT_FILE"
fi
staging=$(mktemp -d "$data_home/graftty/releases/.install-XXXXXX")
service_file="$config_home/systemd/user/graftty-host.service"
service_backup=$(mktemp)
had_service=0
if [[ -f $service_file ]]; then cp "$service_file" "$service_backup"; had_service=1; fi

previous_release=""
release_installed=0
was_running=0
completed=0
replacement_started=0
commands=(graftty graftty-host zmx)
old_links=()
for binary in "${commands[@]}"; do
    old_links+=("$(readlink "$HOME/.local/bin/$binary" 2>/dev/null || true)")
done
cleanup() {
    if ((!completed && replacement_started)); then
        systemctl --user stop graftty-host.service || true
    fi
    if ((!completed && (was_running || maintenance))); then
        if ((release_installed)); then
            rm -rf -- "$release"
        fi
        # A failed/cancelled publication can leave the old release renamed
        # before release_installed is set. Restore that directory independently.
        if [[ -n $previous_release && -e $previous_release ]]; then
            rm -rf -- "$release"
            mv -- "$previous_release" "$release"
        fi
        if ((had_service)); then cp "$service_backup" "$service_file"; else rm -f -- "$service_file"; fi
        for index in "${!commands[@]}"; do
            link="$HOME/.local/bin/${commands[$index]}"
            if [[ -n ${old_links[$index]} ]]; then ln -sfn "${old_links[$index]}" "$link"
            elif [[ -L $link ]]; then rm -- "$link"; fi
        done
        if ((was_running)); then
            systemctl --user daemon-reload || true
            systemctl --user start graftty-host.service || echo 'Could not restore the previous host service' >&2
        fi
    fi
    [[ -z ${staging:-} ]] || rm -rf -- "$staging"
    rm -f -- "$service_backup"
    rm -f -- "$service_backup.next"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if ((maintenance)); then
    ((had_service)) || { echo 'Maintenance requires the existing user service' >&2; exit 1; }
    command -v python3 >/dev/null || { echo 'Maintenance requires python3' >&2; exit 1; }
    if ((start_service)); then
        systemctl --user is-active --quiet graftty-host.service || { echo 'Maintenance requires the existing user service to be active' >&2; exit 1; }
        effective_kill=$(systemctl --user show graftty-host.service --property=KillMode --value)
        [[ $effective_kill == process ]] || { echo 'Maintenance requires effective KillMode=process to preserve sessions' >&2; exit 1; }
        fragment=$(systemctl --user show graftty-host.service --property=FragmentPath --value)
        [[ $(readlink -f -- "$fragment") == $(readlink -f -- "$service_file") ]] || { echo 'Maintenance requires the installed user service file; update custom services manually' >&2; exit 1; }
        unit_text=$(systemctl --user cat graftty-host.service)
        exec_count=$(printf '%s\n' "$unit_text" | grep -c '^[[:space:]]*ExecStart[[:space:]]*=' || true)
        [[ $exec_count == 1 ]] || { echo 'Maintenance cannot replace a service with ExecStart overrides; update that service manually' >&2; exit 1; }
    fi
    # Preserve all service options, environment and drop-ins. Replace only the
    # old bundle path; never rerun setup or rewrite host configuration.
    old_release=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$HOME/.local/bin/graftty-host")
    python3 - "$service_file" "$service_backup.next" "$old_release" "$release" <<'GRAFTTY_PRESERVE_UNIT_049D'
import pathlib, re, sys
source, output, old, new = sys.argv[1:]
text = pathlib.Path(source).read_text()
def systemd_path(value):
    return value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '$$')
old, new = systemd_path(old), systemd_path(new)
if not re.search(r'^KillMode=process\s*$', text, re.M) or old + '/bin/graftty-host' not in text:
    raise SystemExit('Maintenance requires a bundle service with KillMode=process')
match = re.search(r'--ssh-port ([0-9]+)(?:\s|$)', text)
if not match or not 1 <= int(match[1]) <= 65535:
    raise SystemExit('Cannot determine the existing service SSH port')
lines = text.splitlines(keepends=True)
pathlib.Path(output).write_text(''.join(line.replace(old + '/', new + '/') if line.startswith('ExecStart=') else line for line in lines))
GRAFTTY_PRESERVE_UNIT_049D
    ssh_port=$(python3 -c 'import re,sys; print(re.search(r"--ssh-port ([0-9]+)", open(sys.argv[1]).read())[1])' "$service_file")
fi
for directory in bin lib libexec share; do
    [[ -d $source_dir/$directory ]] || { echo "Missing archive directory: $directory" >&2; exit 1; }
    cp -a "$source_dir/$directory" "$staging/$directory"
done
cp "$source_dir/VERSION" "$staging/VERSION"
# Release the host state lease before setup. KillMode=process preserves zmx.
if ((start_service)) && systemctl --user is-active --quiet graftty-host.service; then
    was_running=1
    systemctl --user stop graftty-host.service
fi
# Replace the directory rather than overwrite executables held by running hosts.
if [[ -e $release ]]; then
    previous_release="$release.previous.$(date +%s).$$"
    mv -- "$release" "$previous_release"
fi
mv -- "$staging" "$release"
staging=""
release_installed=1
for binary in graftty graftty-host zmx; do
    ln -sfn "$release/bin/$binary" "$HOME/.local/bin/$binary"
done
# Quote paths for systemd's ExecStart parser. These are not shell commands.
service_executable=${release//\\/\\\\}
service_executable=${service_executable//\"/\\\"}
service_executable=${service_executable//\$/\$\$}
service_bind=${bind_address//%/%%}
if ((maintenance)); then
    cp "$service_backup.next" "$service_file"
else
cat > "$service_file" <<EOF
[Unit]
Description=Graftty Linux host
After=network.target

[Service]
Type=simple
ExecStart="$service_executable/bin/graftty-host" serve --bind-address $service_bind --ssh-port $ssh_port --http-port $http_port --zmx "$service_executable/bin/zmx"
Restart=on-failure
RestartSec=2
KillMode=process
TimeoutStopSec=15
UMask=0077

[Install]
WantedBy=default.target
EOF
fi
if ((start_service)); then
    if ((!maintenance)); then "$release/bin/graftty-host" setup --json >/dev/null; fi
    systemctl --user daemon-reload
    if ((!maintenance)); then systemctl --user enable graftty-host.service; fi
    replacement_started=1
    systemctl --user restart graftty-host.service
    ready_timeout=${GRAFTTY_INSTALL_READY_TIMEOUT_SECONDS:-30}
    [[ $ready_timeout =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid readiness timeout' >&2; exit 64; }
    deadline=$((SECONDS + ready_timeout))
    ready=0
    running_pattern='"running"[[:space:]]*:[[:space:]]*true([,}]|[[:space:]])'
    port_pattern="\"sshPort\"[[:space:]]*:[[:space:]]*$ssh_port([,}]|[[:space:]])"
    while ((SECONDS < deadline)); do
        if status=$(timeout --kill-after=1 2 "$release/bin/graftty-host" status --json 2>/dev/null) &&
           [[ $status =~ $running_pattern && $status =~ $port_pattern ]]; then
            if ((maintenance)) && ! systemctl --user is-active --quiet graftty-host.service; then
                sleep 0.1
                continue
            fi
            ready=1
            break
        fi
        sleep 0.1
    done
    ((ready)) || { echo 'Graftty host did not become ready on the requested SSH port' >&2; exit 1; }
fi
completed=1
printf 'Installed Graftty %s in %s\n' "$version" "$release"
printf 'Add %s/.local/bin to PATH.\n' "$HOME"

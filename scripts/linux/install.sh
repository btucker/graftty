#!/usr/bin/env bash
set -euo pipefail
# Installs for the invoking user. No sudo or system-wide service is needed.
usage() {
    echo 'Usage: ./install.sh [--bind-address ADDRESS] [--ssh-port PORT] [--http-port PORT] [--no-start]'
}
bind_address=127.0.0.1
ssh_port=8801
http_port=8800
start_service=1
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
[[ $version =~ ^[a-zA-Z0-9._-]+$ ]] || { echo 'Invalid archive version' >&2; exit 1; }
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
[[ $data_home == /* && $config_home == /* ]] || { echo 'XDG directories must be absolute paths' >&2; exit 1; }
release="$data_home/graftty/releases/$version"
# systemd expands percent specifiers and rejects newlines in command arguments.
for path in "$release" "$HOME/.local/bin" "$config_home"; do
    [[ $path != *$'\n'* && $path != *$'\r'* && $path != *'%'* ]] || { echo 'Unsupported install path' >&2; exit 1; }
done
mkdir -p "$data_home/graftty/releases" "$HOME/.local/bin" "$config_home/systemd/user"
staging=$(mktemp -d "$data_home/graftty/releases/.install-XXXXXX")
trap '[[ -z ${staging:-} ]] || rm -rf -- "$staging"' EXIT
for directory in bin lib libexec share; do
    [[ -d $source_dir/$directory ]] || { echo "Missing archive directory: $directory" >&2; exit 1; }
    cp -a "$source_dir/$directory" "$staging/$directory"
done
cp "$source_dir/VERSION" "$staging/VERSION"
# Replace the directory rather than overwrite executables held by running hosts.
if [[ -e $release ]]; then
    mv -- "$release" "$release.previous.$(date +%s).$$"
fi
mv -- "$staging" "$release"
staging=""
for binary in graftty graftty-host zmx; do
    ln -sfn "$release/bin/$binary" "$HOME/.local/bin/$binary"
done
# Quote paths for systemd's ExecStart parser. These are not shell commands.
service_executable=${release//\\/\\\\}
service_executable=${service_executable//\"/\\\"}
service_executable=${service_executable//\$/\$\$}
service_bind=${bind_address//%/%%}
cat > "$config_home/systemd/user/graftty-host.service" <<EOF
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
if ((start_service)); then
    "$release/bin/graftty-host" setup --json >/dev/null
    systemctl --user daemon-reload
    systemctl --user enable graftty-host.service
    systemctl --user restart graftty-host.service
fi
printf 'Installed Graftty %s in %s\n' "$version" "$release"
printf 'Add %s/.local/bin to PATH.\n' "$HOME"

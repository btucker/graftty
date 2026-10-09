#!/usr/bin/env bash
set -euo pipefail
archive=${1:?Usage: smoke-test.sh ARCHIVE}
archive=$(readlink -f -- "$archive")
docker run --rm -i --mount "type=bind,source=$archive,target=/artifact.tar.gz,readonly" ubuntu:24.04 bash -s <<'SMOKE'
set -euo pipefail
# The stock Ubuntu image has no Swift installation.
! command -v swift
mkdir /bundle
tar -xzf /artifact.tar.gz --strip-components=1 -C /bundle
export HOME=/tmp/graftty-user
mkdir -p "$HOME"
/bundle/install.sh --bind-address 127.0.0.1 --ssh-port 18001 --http-port 18000 --no-start
export PATH="$HOME/.local/bin:$PATH"
graftty-host --help
graftty --help
zmx version
export GRAFTTY_STATE_DIR=/tmp/graftty-state
export GRAFTTY_SOCK=/tmp/graftty-socket/graftty.sock
graftty-host setup --json --runtime-directory /tmp/graftty-socket
# Runtime linkage was checked before adding Git for the fixture repository.
apt-get update >/dev/null
apt-get install -y --no-install-recommends git >/dev/null
mkdir /tmp/fixture
git -C /tmp/fixture init -q -b main
git -C /tmp/fixture -c user.name=Smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m fixture
graftty-host project add /tmp/fixture --json --runtime-directory /tmp/graftty-socket
grep -q '^KillMode=process$' "$HOME/.config/systemd/user/graftty-host.service"
host_pid=""
trap 'if [[ -n $host_pid ]]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; fi' EXIT
start_host() {
    graftty-host serve --bind-address 127.0.0.1 --ssh-port 18001 --http-port 18000 \
        --runtime-directory /tmp/graftty-socket > /tmp/graftty-serve.log 2>&1 &
    host_pid=$!
    for attempt in $(seq 1 100); do
        if graftty-host status --json --runtime-directory /tmp/graftty-socket 2>/dev/null | grep -q '"running":true'; then return; fi
        if ! kill -0 "$host_pid" 2>/dev/null; then cat /tmp/graftty-serve.log; return 1; fi
        sleep 0.1
    done
    cat /tmp/graftty-serve.log
    return 1
}
start_host
graftty pane add fixture --command 'echo GRAFTTY_READY; exec bash'
graftty pane list fixture
graftty pane send fixture:1 'export GRAFTTY_PERSIST_PROBE=survives'
before=$(ZMX_DIR=/tmp/graftty-state/zmx zmx list --short | sort)
[[ -n $before ]]
# TERM the main host only, matching the installed KillMode=process policy.
kill -TERM "$host_pid"
wait "$host_pid" || true
host_pid=""
[[ $(ZMX_DIR=/tmp/graftty-state/zmx zmx list --short | sort) == "$before" ]]
start_host
[[ $(ZMX_DIR=/tmp/graftty-state/zmx zmx list --short | sort) == "$before" ]]
graftty pane send fixture:1 'printf "GRAFTTY_PERSIST=%s\n" "$GRAFTTY_PERSIST_PROBE"'
found_marker=0
for attempt in $(seq 1 100); do
    output=$(graftty pane show fixture:1 --lines 100)
    if [[ $output == *GRAFTTY_PERSIST=survives* ]]; then found_marker=1; break; fi
    sleep 0.1
done
[[ $found_marker == 1 ]] || { echo "$output"; exit 1; }
graftty-host status --json --runtime-directory /tmp/graftty-socket
SMOKE

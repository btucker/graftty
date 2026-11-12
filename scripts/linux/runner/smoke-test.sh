#!/usr/bin/env bash
set -euo pipefail
image=${1:?Usage: smoke-test.sh IMAGE}
name="graftty-runner-test-$(date +%s)-$$"
volume="$name-home"
cleanup() {
    status=$?
    if (( status != 0 )); then docker logs "$name" >&2 || true; fi
    docker rm --force "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$volume" >/dev/null
start() {
    docker run --detach --name "$name" --hostname graftty-runner \
        --health-interval 1s --health-start-period 1s \
        --mount "type=volume,source=$volume,target=/home/runner" \
        --publish 127.0.0.1::8800 --publish 127.0.0.1::8801 "$image" >/dev/null
    for _ in $(seq 1 100); do
        if [[ $(docker inspect --format '{{.State.Health.Status}}' "$name") == healthy ]]; then return; fi
        [[ $(docker inspect --format '{{.State.Running}}' "$name") == true ]] || return 1
        sleep 0.2
    done
    echo 'Runner did not become ready' >&2
    return 1
}
start
docker exec "$name" graftty-host status --json | grep -q '"running":true'
[[ $(docker exec "$name" id -u) == 10001 ]]
[[ $(docker exec "$name" cat /proc/1/comm) == tini ]]
docker exec "$name" graftty --help >/dev/null
docker exec "$name" zmx version
# Exercise both published listeners, rather than relying only on the local socket.
http_port=$(docker port "$name" 8800/tcp)
curl --silent --show-error --max-time 5 "http://$http_port/" >/dev/null
ssh_port=$(docker port "$name" 8801/tcp)
python3 - "$ssh_port" <<'PY'
import socket, sys
host, port = sys.argv[1].rsplit(':', 1)
with socket.create_connection((host, int(port)), timeout=5) as connection:
    assert connection.recv(255).startswith(b'SSH-2.0-')
PY
project=/home/runner/projects/fixture
docker exec "$name" bash -c 'git init -q -b main fixture && git -C fixture -c user.name=Smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m fixture'
docker exec "$name" graftty-host project add "$project" --json >/dev/null
docker exec "$name" graftty pane add "$project"
docker exec "$name" graftty pane send "$project:1" 'command -v graftty; command -v zmx'
docker exec "$name" graftty pane send "$project:1" 'export GRAFTTY_PROBE=container_ok'
docker exec "$name" graftty pane send "$project:1" 'printf "RUNNER_OUTPUT=%s\n" "$GRAFTTY_PROBE"'
found=0
for _ in $(seq 1 100); do
    output=$(docker exec "$name" graftty pane show "$project:1" --lines 100)
    if [[ $output == *RUNNER_OUTPUT=container_ok* ]]; then found=1; break; fi
    sleep 0.2
done
[[ $found == 1 ]] || { echo "$output" >&2; exit 1; }
[[ $output == */bin/graftty* && $output == */bin/zmx* ]] || { echo "$output" >&2; exit 1; }
# Compare hashes without printing the private identity file.
identity_before=$(docker exec "$name" sha256sum /home/runner/.local/share/graftty/Remote/host-identity.json)
docker stop --time 10 "$name" >/dev/null
[[ $(docker inspect --format '{{.State.ExitCode}}' "$name") == 0 ]]
docker rm "$name" >/dev/null
start
identity_after=$(docker exec "$name" sha256sum /home/runner/.local/share/graftty/Remote/host-identity.json)
[[ $identity_before == "$identity_after" ]]
docker exec "$name" git -C "$project" rev-parse --verify HEAD >/dev/null
docker exec "$name" graftty-host status --json | grep -q '"repositoryCount":1'
echo 'Runner passed non-root startup, listeners, terminal I/O, graceful stop, and persistent-volume replacement.'

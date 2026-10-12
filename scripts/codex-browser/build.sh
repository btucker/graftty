#!/usr/bin/env bash
# Build a matching Codex TUI with an opt-in pane browser helper. No app/provider restart.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: scripts/codex-browser/build.sh CACHE_DIRECTORY OUTPUT_DIRECTORY' >&2
  exit 2
fi
[[ $(uname -s) == Darwin ]] || { echo 'This managed launcher currently supports macOS.' >&2; exit 1; }
patch_dir=$(cd "$(dirname "$0")" && pwd)
pin=092d3acd6bec3e3a14bdc7e7a2810ab628ab759d
version=0.162.1
for tool in git python3 rustup codesign shasum; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
cargo_path=$(rustup which --toolchain 1.95.0 cargo)
rust_bin=$(dirname "$cargo_path")
mkdir -p "$1" "$2"
cache=$(cd "$1" && pwd)
output=$(cd "$2" && pwd)
if [[ ${GRAFTTY_CODEX_BUILD_LOCK_HELD:-} != "$output" ]]; then
  exec /usr/bin/lockf -k "$output/.build.lock" env GRAFTTY_CODEX_BUILD_LOCK_HELD="$output" \
    /bin/bash "$patch_dir/build.sh" "$cache" "$output"
fi
fingerprint=$({ printf '%s\n' "$pin" "$version"; cat "$patch_dir/browser_command.rs" "$patch_dir/apply.py" "$patch_dir/build.sh"; } | shasum -a 256 | awk '{print $1}')
work="$cache/$fingerprint"
if [[ ${GRAFTTY_CODEX_CACHE_LOCK_HELD:-} != "$work" ]]; then
  # Distinct output directories can still share this checkout and build tree.
  exec /usr/bin/lockf -k "$cache/$fingerprint.lock" env GRAFTTY_CODEX_CACHE_LOCK_HELD="$work" \
    /bin/bash "$patch_dir/build.sh" "$cache" "$output"
fi
source="$work/source"
mkdir -p "$work"
if [[ ! -f "$work/patched" ]]; then
  [[ ! -e "$source" ]] || { echo "Incomplete checkout exists at $source; inspect before retrying." >&2; exit 1; }
  git init --quiet "$source"
  git -C "$source" remote add origin https://github.com/openai/codex.git
  git -C "$source" fetch --quiet --depth 1 origin "$pin"
  git -C "$source" checkout --quiet --detach FETCH_HEAD
  [[ $(git -C "$source" rev-parse HEAD) == "$pin" ]]
  python3 "$patch_dir/apply.py" "$source"
  # The release tag updates workspace versions but leaves its lock entries at 0.0.0.
  # Normalize only those entries; every external dependency stays exactly locked.
  python3 - "$source/codex-rs/Cargo.lock" "$version" <<'PY'
import pathlib, re, sys
path, version = pathlib.Path(sys.argv[1]), sys.argv[2]
old = path.read_text()
def normalize(match):
    block = match.group()
    if '\nsource = ' not in block:
        block = block.replace('version = "0.0.0"', f'version = "{version}"', 1)
    return block
new = re.sub(r'\[\[package\]\][\s\S]*?(?=\n\[|\Z)', normalize, old)
external = lambda text: [p for p in re.findall(r'\[\[package\]\][\s\S]*?(?=\n\[|\Z)', text) if '\nsource = ' in p]
assert external(old) == external(new)
path.write_text(new)
PY
  touch "$work/patched"
fi
[[ $(git -C "$source" rev-parse HEAD) == "$pin" ]] || { echo 'Cached Codex source revision differs.' >&2; exit 1; }
python3 "$patch_dir/apply.py" --check "$source"
"$rust_bin/rustc" --test "$patch_dir/browser_command.rs" -o "$work/browser-tests"
"$work/browser-tests"
(
  cd "$source/codex-rs"
  # Compact artifacts avoid a large debug/incremental cache.
  PATH="$rust_bin:$PATH" CARGO_TARGET_DIR="$work/target" CARGO_INCREMENTAL=0 \
    CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_LTO=off \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    "$rust_bin/cargo" build --locked --release --package codex-cli --bin codex -j 2
)
binary="$work/target/release/codex"
[[ $("$binary" --version) == "codex-cli $version" ]]
codesign --force --sign - "$binary"
codesign --verify --strict "$binary"
stage=$(mktemp "$output/.codex.XXXXXXXX")
trap 'rm -f "$stage"' EXIT
cp "$binary" "$stage"
chmod 755 "$stage"
mv "$stage" "$output/codex"
python3 - "$output" "$pin" "$fingerprint" "$source/codex-rs/Cargo.lock" <<'PY'
import hashlib, json, pathlib, sys
output, pin, patch, lock = sys.argv[1:]
sha = lambda path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
receipt = {'codexVersion': '0.162.1', 'sourceCommit': pin, 'patchFingerprint': patch,
           'binarySHA256': sha(pathlib.Path(output) / 'codex'), 'cargoLockSHA256': sha(lock),
           'toolchain': '1.95.0', 'profile': 'release; debug=0; lto=off; incremental=0; jobs=2',
           'scope': 'TUI opener only; official app-server and OAuth flow unchanged'}
(pathlib.Path(output) / 'BUILD.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
echo "Prepared $output/codex. Existing Codex processes are unchanged."

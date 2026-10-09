#!/usr/bin/env bash
set -euo pipefail
executable=$(readlink -f -- "$0")
bundle=$(cd "$(dirname "$executable")/.." && pwd)
export LD_LIBRARY_PATH="$bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$bundle/bin:$PATH"
export TERMINFO_DIRS="$bundle/share/terminfo${TERMINFO_DIRS:+:$TERMINFO_DIRS}"
export GHOSTTY_RESOURCES_DIR="${GHOSTTY_RESOURCES_DIR:-$bundle/share/ghostty}"
case "$(basename "$executable")" in
    graftty) exec "$bundle/libexec/graftty-cli" "$@" ;;
    graftty-host) exec "$bundle/libexec/graftty-host" "$@" ;;
    *) echo 'Unknown Graftty launcher' >&2; exit 1 ;;
esac

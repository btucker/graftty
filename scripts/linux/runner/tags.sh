#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
version=${1:?Usage: tags.sh RELEASE_VERSION}
version=${version#v}
# Reuse the release validator and stable/prerelease classification.
metadata=$("$repo/scripts/release-metadata.sh" "$version" 1 1)
tag=${version//+/_}
(( ${#tag} <= 128 )) || { echo 'Version exceeds the Docker tag length limit' >&2; exit 64; }
printf '%s\n' "$tag"
if grep -q '^prerelease=false$' <<< "$metadata"; then
    printf '%s\n' latest
fi

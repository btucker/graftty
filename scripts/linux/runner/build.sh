#!/usr/bin/env bash
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd)
archive=${1:?Usage: build.sh ARCHIVE [IMAGE]}
image=${2:-graftty-runner:local}
case "$archive" in
    *-x86_64.tar.gz) platform=linux/amd64 ;;
    *-aarch64.tar.gz) platform=linux/arm64 ;;
    *) echo 'Archive name must include its supported architecture' >&2; exit 64 ;;
esac
[[ -f $archive ]] || { echo "Missing Linux archive: $archive" >&2; exit 66; }
context=$(mktemp -d)
trap 'rm -rf -- "$context"' EXIT
# Never send a checkout, home directory, or credentials to the image builder.
cp "$recipe/Dockerfile" "$context/Dockerfile"
cp "$archive" "$context/graftty-linux.tar.gz"
docker build --platform "$platform" --tag "$image" "$context"

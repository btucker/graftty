#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: release-metadata.sh <version> <github-run-number> <github-run-attempt>" >&2
  exit 2
fi

version="$1"
run_number="$2"
run_attempt="$3"

if [[ -z "$version" || ! "$version" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  echo "version must match [A-Za-z0-9._+-]+" >&2
  exit 2
fi
if [[ ! "$run_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "GitHub run number must be a positive integer" >&2
  exit 2
fi
if [[ ! "$run_attempt" =~ ^[1-9][0-9]*$ ]] || ((10#$run_attempt > 100)); then
  echo "GitHub run attempt must be between 1 and 100" >&2
  exit 2
fi

# Start the new build-number series well above Graftty's historical 0.x.y
# bundle versions. Split a single increasing serial into Apple's documented
# three numeric CFBundleVersion components while retaining the ordering. Each
# workflow run reserves 100 values so a rerun gets a new appcast version and
# signature instead of replacing the zip behind an existing appcast item.
serial=$((1000000 + (10#$run_number * 100) + 10#$run_attempt - 1))
major=$((serial / 10000))
minor=$(((serial / 100) % 100))
patch=$((serial % 100))
if ((major > 9999)); then
  echo "GitHub run number is too large for CFBundleVersion" >&2
  exit 2
fi
build_version=$(printf '%d.%02d.%02d' "$major" "$minor" "$patch")

# SemVer build metadata follows '+', but only a suffix before '+' denotes a
# prerelease. This keeps a tag like 0.6.0+notarized.1 on the stable channel.
version_without_build_metadata="${version%%+*}"
if [[ "$version_without_build_metadata" == *-* ]]; then
  prerelease=true
  channel=prerelease
else
  prerelease=false
  channel=
fi

printf 'version=%s\n' "$version"
printf 'build_version=%s\n' "$build_version"
printf 'prerelease=%s\n' "$prerelease"
printf 'channel=%s\n' "$channel"

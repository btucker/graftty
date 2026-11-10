#!/bin/sh
# Xcode Cloud runs this after cloning and before resolving packages.
# Package.swift reads libghostty from .deps/, which scripts/deps builds from
# the pinned Ghostty commit and patch series in deps/ghostty (downloading the
# pinned Zig on first use). GrafttyMobile needs only the iOS slices.
set -eu
"$CI_PRIMARY_REPOSITORY_PATH/scripts/deps" prepare ghostty --platforms ios

# Ghostty paging experiment

This directory contains the renderer patches and probes for the shared
[Mac and mobile paging design](../../docs/superpowers/specs/2026-09-05-shared-paged-terminal-history.md).
Use the [local package build guide](BUILD.md) to build the dependency used by
GrafttyMobile. The instructions below reproduce the original core and surface
experiments. See [the results](RESULTS.md) for the measured behavior and limits.

## Reproduce the core test

Use macOS with the Xcode command-line tools and Zig 0.16.0. The test builds
Ghostty's VT library, not its Metal renderer. The first build downloads Zig
dependencies. Build artifacts remain in the temporary directory printed by
the script.

1. Clone an isolated Ghostty source tree at the revision used by zmx:

   ```bash
   probe_source=$(mktemp -d /tmp/graftty-paging-source.XXXXXX)
   git clone https://github.com/ghostty-org/ghostty "$probe_source/ghostty"
   git -C "$probe_source/ghostty" checkout --detach 8af6897c0afc63037a8a3efee4162a380e3a4572
   ```

2. From the Graftty repository root, apply the experimental core patches:

   ```bash
   git -C "$probe_source/ghostty" apply "$PWD/scripts/ghostty-paging/preserve-top-anchor.patch"
   git -C "$probe_source/ghostty" apply "$PWD/scripts/ghostty-paging/resize-history-guard.patch"
   ```

3. Run the tests with the path to Zig 0.16.0:

   ```bash
   scripts/ghostty-paging/test-core.sh "$probe_source/ghostty" /path/to/zig
   ```

The script runs the `PageAllocation` and `incremental decode` Zig tests. It then
builds a ReleaseSafe VT library and runs `probe.c` through the public C API.
To reproduce the original anchor failure, run the same script on a clean source
tree without the patch. The C probe fails its visible-content comparison at
10,000 lines. The added Zig regression also fails when run without the fix.

## Reproduce the native-surface tests

Use an Apple Silicon Mac with Xcode, its Metal toolchain, and Zig 0.16.0.
Use the isolated source tree from the core test above. Do not apply these
experimental patches to a shared dependency checkout or a release build.

1. If the Metal compiler is missing, install the Xcode component:

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   xcrun metal --version
   ```

2. Apply the shared bridge patch and the iOS build patch, in order:

   ```bash
   git -C "$probe_source/ghostty" apply "$PWD/scripts/ghostty-paging/renderer-experiment.patch"
   git -C "$probe_source/ghostty" apply "$PWD/scripts/ghostty-paging/ios-renderer-experiment.patch"
   ```

3. Run the AppKit tests:

   ```bash
   scripts/ghostty-paging/test-surfaces.sh "$probe_source/ghostty" /path/to/zig
   ```

4. To run both AppKit and UIKit, choose an iOS Simulator UDID and pass it as
   the third argument:

   ```bash
   xcrun simctl list devices available
   scripts/ghostty-paging/test-surfaces.sh "$probe_source/ghostty" /path/to/zig SIMULATOR_UDID
   ```

The runner builds isolated libraries, generates two trusted 100,000-row snapshots,
and opens test windows. With a simulator UDID, it also boots that simulator if
needed and installs `dev.graftty.snapshot-probe`. It does not replace Graftty or
GrafttyMobile. Each platform must print passing markers for scenarios 0, 1,
2, 3, 4, 5, and 6. Scenarios 2 through 4 require recovery without consuming pending
pages. They do not perform checkpoint recovery. Scenario 5 checks height-only
resizing and completion after a later width change. Scenario 6 checks restored
input modes and the synchronized-output timeout. The runner also verifies
presented IOSurface dimensions and rejection of stale frames. It targets the
M1 instruction-set baseline for the arm64 simulator. See [the results and
limitations](RESULTS.md).

The scripts keep build artifacts in the printed temporary directories. Set
`ZIG_GLOBAL_CACHE_DIR` to reuse an existing Zig download and compilation cache.
The tests do not require changes to Graftty's SwiftPM cache or dependency pins.

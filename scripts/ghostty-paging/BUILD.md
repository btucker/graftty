# Build the paging renderer package

Ordinary SwiftPM and Xcode builds use the committed published `libghostty-spm`
dependency, even when `.dependencies/libghostty-spm` exists. To enable paging,
build the local renderer and select it explicitly.
The package includes the current-screen restore, scrollback-page, and read-only
history APIs used by the Mac and iOS apps. CI and release builds create this package
through `.github/actions/paging-renderer`, which exports the explicit package path
and requires paging. Release bundling selects the default local package unless
overridden, and fails if its source pins or patch checksums do not match this checkout.
The history API lets followers fill spare
vertical space above the live grid with earlier rows. The published dependency
does not yet include these APIs. Without the local package, builds continue using
the legacy attachment path and show only the fitted live grid.

Mac attachments restore the current screen first, then import one older history
page at a time in the background. Local panes negotiate directly with zmx; remote
Mac panes request the paged SSH subsystem. New sessions and daemons without paging
support still use the legacy attachment path. Existing daemons keep running across
app upgrades, so an older daemon continues to use that fallback until its session
is restarted.

Paged attachments pin the native parser to the last grid consumed from the
ordered source stream. Local layout and font changes still report physical
viewport intent to the host; they do not reflow the parser before the source's
resize acknowledgment. The source-grid operation shares the mobile output queue,
so earlier VT finishes first. Legacy fallback releases the pin before parsing
legacy output. Terminal size reports use the host-managed parser's current
geometry, including while a physical resize is pending.

Use macOS with Xcode, the iOS SDK, and Zig 0.16.0. The first build downloads the
pinned source repositories and their Zig dependencies. Build all five architecture
slices with this command from the repository root:

```bash
scripts/ghostty-paging/build-package.sh --zig /path/to/zig-0.16.0/zig
```

The script writes `.dependencies/libghostty-spm`. It includes universal macOS,
arm64 iOS, and universal iOS Simulator archives in `BinaryTarget/GhosttyKit.xcframework`.
Its `PAGING-BUILD.txt` records both source revisions and the patch checksums.
The script does not upload or publish the package.

If the Metal compiler is missing, install the Xcode component before building:

```bash
xcodebuild -downloadComponent MetalToolchain
```

After the package build finishes, resolve package dependencies again in Xcode.
Launch Xcode with `GRAFTTY_GHOSTTY_PACKAGE_PATH` in its environment to opt in.
For Xcode Archive, use the same explicit path and set
`GRAFTTY_REQUIRE_PAGED_HISTORY=1` in Xcode's launch environment. Plain SwiftPM
Release builds retain the published development fallback; `bundle.sh` and CI
require paging for production.
Xcode can cache an explicitly selected package's manifest without tracking the
files it reads. For local renderer iteration, use the command-line wrapper below
or select a new package output path after rebuilding.
Ordinary builds with no override do not depend on local renderer files.
For `xcodebuild`, set `GRAFTTY_GHOSTTY_PACKAGE_PATH` to the absolute local package
path and pass `'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG GRAFTTY_PAGED_HISTORY'`
when testing a Debug build. This also enables the native integration tests when
Xcode retains build settings from the published dependency. Confirm that
`checkpointInstallsInARealCanvasWhoseContainerHasDifferentDimensions` runs rather
than being skipped.
For command-line builds, use the repository wrapper:

```bash
GRAFTTY_GHOSTTY_PACKAGE_PATH="$PWD/.dependencies/libghostty-spm" scripts/swiftpm test
```

For an Apple Silicon development build, add `--arm64-only` to omit the two Intel
slices. Build without that flag before preparing artifacts for other machines.
Use `--output PATH` to write another local package. Keep the final directory
name `libghostty-spm` when building the Xcode project, whose package product
references include that name. For either the default or a custom output path,
set `GRAFTTY_GHOSTTY_PACKAGE_PATH=PATH` when resolving or building Graftty.
Explicit overrides are checked against `recipe.json` and the current patches.
Unsetting the override selects the published dependency; old local packages are
ignored with a diagnostic. The shared wrapper and bundle script reevaluate the
manifest on each invocation so rebuilt local headers get a new Clang module
signature. Both wrappers forward that signature as a global compiler flag so
GhosttyKit and GhosttyTerminal dependency targets use it too. This preserves
unrelated cached build products.

When switching renderer packages in an existing Xcode build directory, use the
same context in `xcodebuild`, as CI does:

```bash
export GRAFTTY_GHOSTTY_PACKAGE_PATH="$PWD/.dependencies/libghostty-spm"
export GRAFTTY_REQUIRE_PAGED_HISTORY=1
renderer_context="$(python3 scripts/ghostty-paging/compiler-context.py "$PWD" "$PWD/.build")"
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile -destination 'generic/platform=iOS Simulator' \
  "OTHER_SWIFT_FLAGS=\$(inherited) -Xcc $renderer_context" build
```

For an arm64-only renderer, also pass `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.
Plain `swift build` supports the committed published renderer from a clean build
directory. Use `scripts/swiftpm` when switching or rebuilding local renderer
packages so dependency targets also receive the fresh context.
Set it to an empty string to verify the published renderer's legacy fallback.

Build caches remain in `~/Library/Caches/Graftty/GhosttyPaging`. Use `--cache PATH`
to choose another cache directory. A changed renderer patch selects a new source
cache automatically. Run one package build at a time when sharing a cache.

To verify the native renderer behavior, follow the
[native-surface test instructions](README.md#reproduce-the-native-surface-tests)
and use `production-test-surfaces.sh` for the production snapshot API tests.

Set `GRAFTTY_SELECTION_RESIZE_PROBE=1` when running that test script to also
force a mouse click between a pixel-size change and the terminal's resize.
The test verifies that an invalid click preserves the current selection without
crashing. The script copies the source before applying
`production-selection-probe.patch`; this test-only helper is never included by
`build-package.sh` or in the production package.

## Native link-click regression

Run the isolated AppKit regression against source with all recipe patches applied:

```bash
scripts/ghostty-paging/test-link-clicks.sh /path/to/patched/ghostty /path/to/zig-0.16.0
```

The runner copies the source, builds ReleaseSafe libraries in a new temporary
folder, and captures link-open callbacks in standalone subprocesses. It does
not launch or replace Graftty. Each case checks actual Cmd press and release,
repeated snapshot attachment, URL bytes, terminal input and output, and teardown.
The matrix includes plain and OSC8 links, URI and filesystem working directories,
percent decoding, rejected URI values, prompt state, history, and drag selection.

To test the packaged macOS archive, pass its path as the third argument. To run
the `EDITOR-1.10` Swift Testing entry, set `GRAFTTY_LINK_CLICK_TEST_DIR` to the
printed artifact directory when running `scripts/swiftpm test --filter NativeLinkClickTests`.
The entry is opt-in because these subprocesses require AppKit and Metal access.

The unchanged alpha.18 archive aborts on `snapshot-file-uri`: the VT producer
stores raw OSC 7 `file://localhost/...`, and the native consumer previously passed
a URI-derived relative result to `accessAbsolute`. `snapshot-pwd.patch` normalizes
restored working directories with the live native OSC 7 parser before attachment
and rejects non-absolute resolver bases. The snapshot codec and OSC8 URL handling
retain their existing formats.

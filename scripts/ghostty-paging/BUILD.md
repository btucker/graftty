# Build the paging renderer package

Build the local `libghostty-spm` dependency before opening GrafttyMobile in Xcode.
The package includes the current-screen restore and scrollback-page APIs used by
GrafttyMobile. The published dependency does not yet include these APIs. Without
the local package, builds continue using the legacy attachment path.

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
For command-line builds, use the repository wrapper:

```bash
scripts/swiftpm test
```

For an Apple Silicon development build, add `--arm64-only` to omit the two Intel
slices. Build without that flag before preparing artifacts for other machines.
Use `--output PATH` to write another local package. For a custom output path,
set `GRAFTTY_GHOSTTY_PACKAGE_PATH=PATH` when resolving or building Graftty.
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

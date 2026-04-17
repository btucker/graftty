# zmx Integration Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Espalier pane's PTY child a `zmx attach <session>` process instead of `$SHELL`, so terminal sessions survive Espalier quits, crashes, and relaunches. Native UX otherwise unchanged.

**Architecture:** A vendored `zmx` binary at `Resources/zmx-binary/zmx` is bundled into the .app at `Contents/Helpers/zmx` (mirroring the existing `espalier` CLI placement). A new `ZmxLauncher` (in `EspalierKit`) resolves the binary path, derives session names from pane UUIDs, builds the `zmx attach …` command string, and shells out to `zmx kill` / `zmx list`. `SurfaceHandle` sets `ghostty_surface_config_s.command` to the launcher's invocation; `TerminalManager` calls `kill` on surface destruction. Sessions are scoped to a private `ZMX_DIR` under app support. If the bundled binary is missing/unloadable, `SurfaceHandle` falls back to libghostty's default `$SHELL` spawn behavior and the app surfaces a one-time banner.

**Tech Stack:** Swift 5.10, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftUI/AppKit (macOS 14+), `Process` for subprocess invocation (mirroring `EspalierKit/Git/GitRunner` style), libghostty C API via `GhosttyKit`. Bash for the bump script. zmx is a Zig binary distributed as `.tar.gz` artifacts at `https://zmx.sh/a/`.

**Spec:** `docs/superpowers/specs/2026-04-17-zmx-integration-design.md`

---

## File Structure

**Create (build / vendoring):**
- `scripts/bump-zmx.sh` — fetches latest (or pinned) zmx release for both macOS arches, lipos to a universal binary, writes `VERSION` and `CHECKSUMS`.
- `Resources/zmx-binary/zmx` — committed universal binary (output of bump script).
- `Resources/zmx-binary/VERSION` — committed plain-text version string.
- `Resources/zmx-binary/CHECKSUMS` — committed SHA256s for arm64 + x86_64 + universal.

**Create (EspalierKit):**
- `Sources/EspalierKit/Zmx/ZmxRunner.swift` — sync subprocess wrapper, three flavors mirroring `GitRunner`. Injectable executable URL + env.
- `Sources/EspalierKit/Zmx/ZmxLauncher.swift` — bundled-binary resolution, session naming, attach-command construction, `kill`, `listSessions`, `isAvailable`.
- `Tests/EspalierKitTests/Zmx/ZmxRunnerTests.swift`
- `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift` — pure-logic unit tests.
- `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift` — end-to-end survival contract via real `zmx` subprocess.

**Create (Espalier app):**
- `Sources/Espalier/Views/ZmxFallbackBanner.swift` — small banner shown when `ZmxLauncher.isAvailable == false`.

**Modify:**
- `Package.swift` — no change (the binary is *not* a Swift Package resource; it's copied at bundle time).
- `scripts/bundle.sh` — install `Resources/zmx-binary/zmx` to `Contents/Helpers/zmx` and `chmod +x`.
- `Sources/Espalier/Terminal/SurfaceHandle.swift` — add `zmxCommand: String?` init parameter; if non-nil, set `config.command`.
- `Sources/Espalier/Terminal/TerminalManager.swift` — own a `ZmxLauncher`; pass `zmxCommand` to new surfaces; call `launcher.kill(sessionName:)` from `destroySurface(s)`.
- `Sources/Espalier/EspalierApp.swift` — instantiate `ZmxLauncher`, hand it to `TerminalManager`, present the fallback banner once on launch if unavailable.
- `SPECS.md` — append §13 "zmx Session Backing" (EARS requirements). The existing §11 (Worktree Divergence Indicator) and §12 (Technology Constraints) stay; this becomes §13.

---

## Test Infrastructure Notes

The Espalier *app* target has no test target today (`ls Tests/` shows only `EspalierKitTests/`). The spec's "end-to-end survival via TerminalManager" test is therefore implemented as `ZmxSurvivalIntegrationTests` inside `EspalierKitTests`, which exercises `ZmxLauncher` end-to-end (spawn → write marker → close PTY → re-spawn → read marker). The libghostty-mediated path is verified by the manual smoke tests at the end of this plan.

Integration tests skip themselves with `try #require(launcher.isAvailable, "zmx binary not vendored — run scripts/bump-zmx.sh")` so a fresh contributor who hasn't run the bump script gets a clear skip message rather than a confusing failure.

---

## Task 1: Bump script + first vendor of zmx 0.5.0

**Files:**
- Create: `scripts/bump-zmx.sh`
- Create: `Resources/zmx-binary/zmx` (universal binary, ~few MB)
- Create: `Resources/zmx-binary/VERSION`
- Create: `Resources/zmx-binary/CHECKSUMS`

- [ ] **Step 1: Write the bump script**

Create `scripts/bump-zmx.sh`:

```bash
#!/usr/bin/env bash
# Fetch a zmx release for both macOS arches, lipo to a universal
# binary, and update Resources/zmx-binary/{zmx,VERSION,CHECKSUMS}.
#
# Usage:
#   ./scripts/bump-zmx.sh             # bumps to latest GitHub release
#   ZMX_VERSION=0.5.0 ./scripts/bump-zmx.sh   # pins a specific version
#
# Requires: gh, curl, shasum, lipo, tar.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${ZMX_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(gh api repos/neurosnap/zmx/releases/latest --jq .tag_name)
fi
VERSION="${VERSION#v}"
echo "→ vendoring zmx ${VERSION}"

mkdir -p Resources/zmx-binary
TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

declare -a checksums
for arch in arm64 x86_64; do
    url="https://zmx.sh/a/zmx-${VERSION}-macos-${arch}.tar.gz"
    echo "  → fetching $url"
    curl -fL --silent --show-error -o "${TMP}/zmx-${arch}.tar.gz" "$url"
    tar -xzf "${TMP}/zmx-${arch}.tar.gz" -C "$TMP"
    mv "${TMP}/zmx" "${TMP}/zmx-${arch}"
    sha=$(shasum -a 256 "${TMP}/zmx-${arch}" | awk '{print $1}')
    checksums+=("${sha}  zmx-${arch}")
done

lipo -create "${TMP}/zmx-arm64" "${TMP}/zmx-x86_64" -output Resources/zmx-binary/zmx
chmod +x Resources/zmx-binary/zmx

uni_sha=$(shasum -a 256 Resources/zmx-binary/zmx | awk '{print $1}')
checksums+=("${uni_sha}  zmx (universal)")

echo "$VERSION" > Resources/zmx-binary/VERSION
printf "%s\n" "${checksums[@]}" > Resources/zmx-binary/CHECKSUMS

echo
echo "✓ vendored zmx ${VERSION}"
echo "  arm64:     ${checksums[0]%% *}"
echo "  x86_64:    ${checksums[1]%% *}"
echo "  universal: ${uni_sha}"
echo "  size:      $(stat -f%z Resources/zmx-binary/zmx) bytes"
echo
echo "Review the diff and commit."
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x scripts/bump-zmx.sh
ZMX_VERSION=0.5.0 ./scripts/bump-zmx.sh
```

Expected output ends with `✓ vendored zmx 0.5.0` and prints three SHA256s.

- [ ] **Step 3: Verify the binary works**

```bash
Resources/zmx-binary/zmx version
file Resources/zmx-binary/zmx
```

Expected: `version` prints something like `zmx 0.5.0 (...)`. `file` shows `Mach-O universal binary with 2 architectures: [x86_64, arm64]`.

- [ ] **Step 4: Commit**

```bash
git add scripts/bump-zmx.sh Resources/zmx-binary/
git commit -m "$(cat <<'EOF'
build: vendor zmx 0.5.0 universal binary + bump script

Resources/zmx-binary/zmx is a lipo'd arm64+x86_64 build of the
upstream release at https://zmx.sh/a/. Bumped via the new
scripts/bump-zmx.sh. CHECKSUMS records per-arch and universal
SHA256s for tamper detection on future bumps.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Install zmx binary into the .app bundle

**Files:**
- Modify: `scripts/bundle.sh` (between the existing CLI copy and the icon step).

- [ ] **Step 1: Add the install line**

Open `scripts/bundle.sh`. After the line `cp "$BIN_DIR/espalier-cli" "$APP/Contents/Helpers/espalier"` (currently line 35), add:

```bash
echo "→ install bundled zmx"
# zmx is the per-pane PTY child for every Espalier terminal, providing
# session persistence so shells survive app quits. The binary is vendored
# at Resources/zmx-binary/zmx; bundle.sh just copies it into Helpers/.
cp "$REPO/Resources/zmx-binary/zmx" "$APP/Contents/Helpers/zmx"
chmod +x "$APP/Contents/Helpers/zmx"
```

- [ ] **Step 2: Run the bundle script and verify**

```bash
./scripts/bundle.sh
ls -l .build/Espalier.app/Contents/Helpers/
.build/Espalier.app/Contents/Helpers/zmx version
```

Expected: `Helpers/` lists both `espalier` and `zmx` as executables. The `zmx version` invocation prints the version banner.

- [ ] **Step 3: Commit**

```bash
git add scripts/bundle.sh
git commit -m "$(cat <<'EOF'
build: install vendored zmx into Contents/Helpers

The bundle script now copies Resources/zmx-binary/zmx into
Espalier.app/Contents/Helpers/zmx so the runtime can spawn it as
the PTY child for every pane.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `ZmxRunner` — sync subprocess wrapper

**Files:**
- Create: `Sources/EspalierKit/Zmx/ZmxRunner.swift`
- Create: `Tests/EspalierKitTests/Zmx/ZmxRunnerTests.swift`

Mirrors the shape of `Sources/EspalierKit/Git/GitRunner.swift` (66 lines), but with an injectable executable URL and env-passing support.

- [ ] **Step 1: Write the failing tests**

Create `Tests/EspalierKitTests/Zmx/ZmxRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("ZmxRunner")
struct ZmxRunnerTests {

    // We use /bin/echo as a stand-in for any executable — it's universally
    // present and its behavior (echo args + newline) is trivially verifiable.

    @Test func runReturnsStdoutOnZeroExit() throws {
        let result = try ZmxRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            args: ["hello", "world"],
            env: [:]
        )
        #expect(result == "hello world\n")
    }

    @Test func runThrowsOnNonZeroExit() throws {
        // /usr/bin/false is a builtin-ish that always exits 1.
        #expect(throws: ZmxRunner.Error.self) {
            _ = try ZmxRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                args: [],
                env: [:]
            )
        }
    }

    @Test func captureReturnsStdoutAndExitCodeWithoutThrowing() throws {
        let result = try ZmxRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            args: [],
            env: [:]
        )
        #expect(result.stdout == "")
        #expect(result.exitCode == 1)
    }

    @Test func captureAllReturnsStderrSeparately() throws {
        // /bin/sh -c 'echo out; echo err >&2; exit 2'
        let result = try ZmxRunner.captureAll(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo out; echo err >&2; exit 2"],
            env: [:]
        )
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.exitCode == 2)
    }

    @Test func envIsPassedToTheChild() throws {
        let result = try ZmxRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo $ZMX_TEST_VAR"],
            env: ["ZMX_TEST_VAR": "marker"]
        )
        #expect(result == "marker\n")
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile**

Run: `swift test --filter ZmxRunnerTests`
Expected: build error — `ZmxRunner` is undefined.

- [ ] **Step 3: Implement `ZmxRunner`**

Create `Sources/EspalierKit/Zmx/ZmxRunner.swift`:

```swift
import Foundation

/// Sync subprocess wrapper for invoking `zmx` (or any other executable
/// with explicit env). Three flavors mirror `GitRunner`:
///
/// - `run` — throws on non-zero exit; returns stdout
/// - `capture` — returns (stdout, exitCode) without throwing
/// - `captureAll` — returns (stdout, stderr, exitCode) for diagnostics
///
/// Differs from `GitRunner` in two ways: the executable URL is a
/// parameter (not a hardcoded path), and env is explicit (the caller
/// passes exactly what the child should see — empty dict means an
/// almost-empty env, not "inherit").
public enum ZmxRunner {

    public enum Error: Swift.Error, Equatable {
        case zmxFailed(terminationStatus: Int32)
    }

    /// Throws on non-zero exit. Use when nonzero means "the call failed".
    public static func run(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> String {
        let result = try capture(executable: executable, args: args, env: env)
        guard result.exitCode == 0 else {
            throw Error.zmxFailed(terminationStatus: result.exitCode)
        }
        return result.stdout
    }

    /// Returns (stdout, exitCode). Use when the exit code is diagnostic
    /// (e.g., `zmx kill` of a session that already died — nonzero is fine).
    public static func capture(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // stderr → /dev/null per GitRunner's pattern (avoids pipe deadlock
        // on chatty commands; we use captureAll if we need stderr).
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (stdout: out, exitCode: process.terminationStatus)
    }

    /// Returns (stdout, stderr, exitCode). Use when stderr carries the
    /// user-visible error on failure. Both pipes are read; safe for
    /// bounded-output commands. Don't use for chatty long-running output.
    public static func captureAll(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
```

- [ ] **Step 4: Verify the tests pass**

Run: `swift test --filter ZmxRunnerTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Zmx/ZmxRunner.swift Tests/EspalierKitTests/Zmx/ZmxRunnerTests.swift
git commit -m "$(cat <<'EOF'
feat(zmx): ZmxRunner — sync subprocess wrapper

Three flavors (run / capture / captureAll) mirroring GitRunner, with
an injectable executable URL and explicit env passing. Used by
ZmxLauncher to invoke the bundled zmx binary for kill / list calls.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `ZmxLauncher` unit tests + implementation (pure logic)

**Files:**
- Create: `Sources/EspalierKit/Zmx/ZmxLauncher.swift`
- Create: `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift`

Pure-logic surface: session-name derivation, attach-command construction, list parsing, `isAvailable`. No subprocess calls in this task — those are exercised in Task 5.

- [ ] **Step 1: Write the failing tests**

Create `Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("ZmxLauncher — pure logic")
struct ZmxLauncherUnitTests {

    // MARK: sessionName(for:)
    //
    // The session name is the join key between Espalier and the zmx
    // daemon. Once a user upgrades and starts a daemon under a given
    // name, changing this function would orphan that daemon — they'd
    // get a fresh shell instead of their reattached one.

    @Test func sessionNameIsDeterministic() throws {
        let id = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let name = launcher.sessionName(for: id)
        #expect(name == "espalier-deadbeef")
    }

    @Test func sessionNameUsesFirst8HexCharsOfUUID() throws {
        // First 8 hex chars of any UUID are the leading 4 bytes.
        let id = UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.sessionName(for: id) == "espalier-01234567")
    }

    @Test func sessionNameDiffersForDifferentUUIDs() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let a = launcher.sessionName(for: UUID())
        let b = launcher.sessionName(for: UUID())
        #expect(a != b)
    }

    // MARK: attachCommand(sessionName:)
    //
    // libghostty's `command` field is a single string (shell parses it).
    // We single-quote the executable path defensively in case the user
    // installed Espalier somewhere with spaces in the path.

    @Test func attachCommandIncludesQuotedExecutableAndSession() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/Applications/Espalier.app/Contents/Helpers/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "espalier-deadbeef")
        #expect(cmd == "'/Applications/Espalier.app/Contents/Helpers/zmx' attach espalier-deadbeef $SHELL")
    }

    @Test func attachCommandEscapesSingleQuotesInExecutablePath() throws {
        // Path with a single quote — single-quote escaping pattern is
        // ' → '\''  (close, escape, reopen). Defensive even if rare.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/tmp/it's/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "espalier-cafe1234")
        #expect(cmd == "'/tmp/it'\\''s/zmx' attach espalier-cafe1234 $SHELL")
    }

    // MARK: parseListOutput
    //
    // `zmx list --short` emits one session name per line. (The non-short
    // form emits tab-separated key=value pairs; we don't parse that.)

    @Test func parsesEmptyListOutput() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.parseListOutput("") == [])
        #expect(launcher.parseListOutput("\n") == [])
    }

    @Test func parsesSingleSession() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.parseListOutput("espalier-deadbeef\n") == ["espalier-deadbeef"])
    }

    @Test func parsesManySessions() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = """
        espalier-aaaa1111
        espalier-bbbb2222
        espalier-cccc3333
        """
        #expect(
            launcher.parseListOutput(output) ==
            ["espalier-aaaa1111", "espalier-bbbb2222", "espalier-cccc3333"]
        )
    }

    @Test func parseListSkipsBlankLines() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = "espalier-aaaa1111\n\n\nespalier-bbbb2222\n"
        #expect(
            launcher.parseListOutput(output) ==
            ["espalier-aaaa1111", "espalier-bbbb2222"]
        )
    }

    // MARK: isAvailable

    @Test func isAvailableFalseWhenExecutableMissing() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        #expect(launcher.isAvailable == false)
    }

    @Test func isAvailableTrueForExistingExecutable() throws {
        // /bin/sh is universally executable
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(launcher.isAvailable == true)
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile**

Run: `swift test --filter ZmxLauncherUnitTests`
Expected: build error — `ZmxLauncher` is undefined.

- [ ] **Step 3: Implement `ZmxLauncher`**

Create `Sources/EspalierKit/Zmx/ZmxLauncher.swift`:

```swift
import Foundation

/// Resolves the bundled `zmx` binary and translates Espalier pane
/// identifiers into zmx invocations.
///
/// # Lifetime
/// Created once at app startup with the resolved executable URL. The
/// public surface is small and synchronous; use `kill` from a background
/// queue if calling from the UI thread (see TerminalManager).
public final class ZmxLauncher {

    /// URL to the `zmx` binary. May point to a path that does not exist;
    /// callers should consult `isAvailable` before assuming usability.
    public let executable: URL

    /// `ZMX_DIR` value to pass to every spawned `zmx` invocation. Scopes
    /// our daemons under app support so they don't collide with a
    /// user-private `zmx` running in Terminal.app.
    public let zmxDir: URL

    public init(executable: URL, zmxDir: URL) {
        self.executable = executable
        self.zmxDir = zmxDir
    }

    /// Convenience init that defaults `zmxDir` to
    /// `~/Library/Application Support/Espalier/zmx/`. Used by tests that
    /// don't care about the dir.
    public convenience init(executable: URL) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("Espalier", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        self.init(executable: executable, zmxDir: dir)
    }

    /// True when the binary at `executable` exists and is executable by
    /// the current process.
    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Deterministic mapping from a pane UUID to a zmx session name.
    /// **Do not change this mapping** without a migration strategy —
    /// changing it orphans every existing user's daemons.
    ///
    /// Returns `"espalier-" + first-8-hex-of-uuid`. 32 bits of namespace
    /// uniqueness within a single user's `ZMX_DIR` is ample for the
    /// expected concurrent-pane count (dozens, not millions).
    public func sessionName(for paneID: UUID) -> String {
        // UUID's hex string is upper-case with dashes; we want lowercase
        // and just the first 8 chars (the leading 4 bytes).
        let hex = paneID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "espalier-\(hex.prefix(8))"
    }

    /// The single-string command to hand to `ghostty_surface_config_s.command`.
    /// Single-quotes the executable path so spaces or shell metacharacters
    /// in the install path don't break the spawn.
    public func attachCommand(sessionName: String) -> String {
        "\(shellQuote(executable.path)) attach \(sessionName) $SHELL"
    }

    /// Env additions that should accompany every zmx invocation Espalier
    /// makes (both inline subprocess calls AND the libghostty-spawned
    /// `zmx attach` PTY child). Caller merges with any existing env.
    public func envAdditions() -> [String: String] {
        ["ZMX_DIR": zmxDir.path]
    }

    /// `zmx kill --force <session>`. Synchronous; ignores nonzero exit
    /// (the most common nonzero is "session already gone" which is the
    /// successful outcome from our perspective). Logs are caller's
    /// responsibility — pipe stdout/stderr if needed.
    ///
    /// The caller is expected to dispatch this off the main thread.
    public func kill(sessionName: String) {
        guard isAvailable else { return }
        _ = try? ZmxRunner.capture(
            executable: executable,
            args: ["kill", "--force", sessionName],
            env: ProcessInfo.processInfo.environment.merging(envAdditions()) { _, new in new }
        )
    }

    /// `zmx list --short`. Returns the set of session names known to
    /// the zmx daemon set in our `ZMX_DIR`. Throws on launch failure;
    /// returns an empty set on parse failure or unavailability.
    public func listSessions() throws -> Set<String> {
        guard isAvailable else { return [] }
        let output = try ZmxRunner.run(
            executable: executable,
            args: ["list", "--short"],
            env: ProcessInfo.processInfo.environment.merging(envAdditions()) { _, new in new }
        )
        return Set(parseListOutput(output))
    }

    /// Parser exposed for unit testing. Splits on newlines, trims, drops
    /// empties. Each remaining line is treated as a session name.
    func parseListOutput(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Single-quote a string for use as a single shell token. Closes
    /// the quote, escapes any embedded single quotes, then reopens.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 4: Verify the tests pass**

Run: `swift test --filter ZmxLauncherUnitTests`
Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Zmx/ZmxLauncher.swift Tests/EspalierKitTests/Zmx/ZmxLauncherTests.swift
git commit -m "$(cat <<'EOF'
feat(zmx): ZmxLauncher — session-name + attach-command derivation

Pure-logic surface: deterministic session naming from pane UUID
(espalier-<first-8-hex>), attach-command construction with shell
quoting of the binary path, list-output parsing, and isAvailable
checks. The session-name function is a hard contract — changing it
orphans every existing user's daemons.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `ZmxLauncher` integration test — survival contract

**Files:**
- Create: `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift`

This is the **acceptance test** for Phase 1's core invariant: a session detached without `kill` survives, and reattach restores prior screen output. Tests skip themselves if the bundled zmx isn't present.

- [ ] **Step 1: Write the failing test**

Create `Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("ZmxLauncher — survival contract (integration)")
struct ZmxSurvivalIntegrationTests {

    // MARK: Helpers

    /// Locate the bundled zmx binary by walking up from this source file
    /// to the repo root and looking under `Resources/zmx-binary/zmx`.
    /// Returns nil if the binary hasn't been vendored — tests should
    /// `try #require()` on this and surface a helpful skip message.
    static func vendoredZmx() -> URL? {
        // #file resolves to /…/Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift
        // Walk up: Zmx → EspalierKitTests → Tests → repo-root.
        let here = URL(fileURLWithPath: #file)
        let repoRoot = here
            .deletingLastPathComponent()  // Zmx/
            .deletingLastPathComponent()  // EspalierKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        let candidate = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("zmx-binary")
            .appendingPathComponent("zmx")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    /// Allocate a fresh ZMX_DIR under NSTemporaryDirectory, run the
    /// body, then force-kill any leaked sessions on exit.
    static func withScopedZmxDir<T>(_ body: (ZmxLauncher) throws -> T) throws -> T {
        let zmx = try #require(
            vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zmx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let launcher = ZmxLauncher(executable: zmx, zmxDir: tmpDir)
        defer {
            // Reap anything still alive in this scoped dir.
            if let names = try? launcher.listSessions() {
                for name in names {
                    launcher.kill(sessionName: name)
                }
            }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        return try body(launcher)
    }

    /// Spawn a `zmx attach` child the same way libghostty would: as a
    /// subprocess with stdin/stdout pipes, so we can write commands
    /// into the session and read back its output. Returns the running
    /// Process plus its pipes.
    static func spawnAttach(
        launcher: ZmxLauncher,
        sessionName: String
    ) throws -> (process: Process, stdin: FileHandle, stdout: FileHandle) {
        let process = Process()
        // Use /bin/sh -c so libghostty-style command-string parsing
        // matches what production does.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launcher.attachCommand(sessionName: sessionName)]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in launcher.envAdditions() { env[k] = v }
        // Force a deterministic shell so prompt-detection and SHELL
        // expansion behave the same on every dev machine.
        env["SHELL"] = "/bin/sh"
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, stdinPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading)
    }

    /// Wait until `output` contains `marker` or the deadline elapses.
    static func readUntil(
        marker: String,
        from handle: FileHandle,
        deadline: TimeInterval = 5
    ) -> String {
        var accumulated = ""
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            // Non-blocking read of whatever's available.
            let chunk = handle.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                accumulated += s
                if accumulated.contains(marker) { return accumulated }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return accumulated
    }

    // MARK: Tests

    @Test func sessionSurvivesClientDetachAndReattachRestoresMarker() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let marker = "MARKER_\(UUID().uuidString.prefix(8))"

            // ── First client: write the marker into the session. ──────
            let first = try Self.spawnAttach(launcher: launcher, sessionName: session)
            // Echo the marker into the inner shell.
            try first.stdin.write(contentsOf: Data("echo \(marker)\n".utf8))
            // Wait for the marker to appear in the live stream — proves
            // the shell is up and zmx is forwarding bytes.
            let liveOutput = Self.readUntil(marker: marker, from: first.stdout)
            #expect(
                liveOutput.contains(marker),
                "marker never appeared in live output — got: \(liveOutput)"
            )

            // Detach by closing stdin (zmx's recommended detach mechanism)
            // and terminating the client process. Daemon should keep running.
            try first.stdin.close()
            first.process.terminate()
            first.process.waitUntilExit()

            // ── Verify the daemon survived. ───────────────────────────
            let alive = try launcher.listSessions()
            #expect(
                alive.contains(session),
                "session \(session) didn't survive client detach; alive: \(alive)"
            )

            // ── Second client: reattach and verify marker is replayed. ─
            let second = try Self.spawnAttach(launcher: launcher, sessionName: session)
            let replay = Self.readUntil(marker: marker, from: second.stdout)
            #expect(
                replay.contains(marker),
                "reattach didn't restore marker; got: \(replay)"
            )

            // Cleanup
            try? second.stdin.close()
            second.process.terminate()
            second.process.waitUntilExit()
            launcher.kill(sessionName: session)
        }
    }

    @Test func killRemovesSessionFromList() throws {
        try Self.withScopedZmxDir { launcher in
            let session = launcher.sessionName(for: UUID())
            let attach = try Self.spawnAttach(launcher: launcher, sessionName: session)
            // Wait for the session to register before killing it.
            _ = Self.readUntil(marker: "$", from: attach.stdout, deadline: 2)
            try? attach.stdin.close()
            attach.process.terminate()
            attach.process.waitUntilExit()

            #expect(try launcher.listSessions().contains(session))
            launcher.kill(sessionName: session)
            #expect(!(try launcher.listSessions()).contains(session))
        }
    }

    @Test func killOfNonexistentSessionIsHarmless() throws {
        try Self.withScopedZmxDir { launcher in
            // Should not throw and should not crash.
            launcher.kill(sessionName: "espalier-doesnotexist")
        }
    }
}
```

- [ ] **Step 2: Verify the tests run (and pass)**

Run: `swift test --filter ZmxSurvivalIntegrationTests`
Expected: 3 tests pass (vendored binary present from Task 1) OR the tests are skipped if `Resources/zmx-binary/zmx` doesn't exist with a clear message.

- [ ] **Step 3: Commit**

```bash
git add Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift
git commit -m "$(cat <<'EOF'
test(zmx): survival contract integration tests

The acceptance tests for Phase 1's core invariant — sessions survive
client detach, reattach restores prior output, kill removes sessions.
Uses the vendored binary at Resources/zmx-binary/zmx with a scoped
ZMX_DIR per test for isolation. Skips with a helpful message if the
binary hasn't been vendored.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `SurfaceHandle` to spawn via `ZmxLauncher`

**Files:**
- Modify: `Sources/Espalier/Terminal/SurfaceHandle.swift` (init signature + config setup, around lines 45-125)

`SurfaceHandle.init` currently leaves `config.command` unset, so libghostty defaults to spawning `$SHELL`. We add a `zmxCommand: String?` init parameter; if non-nil, set `config.command` to it.

- [ ] **Step 1: Modify `SurfaceHandle.init`**

In `Sources/Espalier/Terminal/SurfaceHandle.swift`, change the init signature and command setup. The full updated init signature and surrounding logic:

Change:

```swift
    init(
        terminalID: TerminalID,
        app: ghostty_app_t,
        worktreePath: String,
        socketPath: String,
        terminalManager: TerminalManager? = nil
    ) {
```

to:

```swift
    init(
        terminalID: TerminalID,
        app: ghostty_app_t,
        worktreePath: String,
        socketPath: String,
        zmxCommand: String? = nil,
        zmxDir: String? = nil,
        terminalManager: TerminalManager? = nil
    ) {
```

In the same init, after the existing `let sockVal = strdup(socketPath)` line, add:

```swift
        // Optional: when ZmxLauncher is available, this is the full
        // `zmx attach <session> $SHELL` invocation that libghostty will
        // spawn instead of the default $SHELL. Nil means "fall back to
        // libghostty's default shell spawn" (the pre-zmx behavior).
        let cmdCStr: UnsafeMutablePointer<CChar>? = zmxCommand.flatMap { strdup($0) }
```

Then update the env-vars block. Currently it allocates capacity 1 for `ESPALIER_SOCK`; we need capacity 2 when `zmxDir` is non-nil, so we can also pass `ZMX_DIR`. Replace:

```swift
        let envVarsPtr = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: 1)
        envVarsPtr.initialize(to: ghostty_env_var_s(key: sockKey, value: sockVal))
```

with:

```swift
        let zmxDirKey: UnsafeMutablePointer<CChar>? = zmxDir.flatMap { _ in strdup("ZMX_DIR") }
        let zmxDirVal: UnsafeMutablePointer<CChar>? = zmxDir.flatMap { strdup($0) }
        let envCount = zmxDir == nil ? 1 : 2

        let envVarsPtr = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: envCount)
        envVarsPtr.initialize(to: ghostty_env_var_s(key: sockKey, value: sockVal))
        if let zmxDirKey, let zmxDirVal {
            envVarsPtr.advanced(by: 1).initialize(
                to: ghostty_env_var_s(key: zmxDirKey, value: zmxDirVal)
            )
        }
```

Then in the config-population block (around the existing `config.env_vars = envVarsPtr` line), add the command line and update the count:

```swift
        config.working_directory = UnsafePointer(cwdCStr)
        if let cmdCStr {
            config.command = UnsafePointer(cmdCStr)
        }
        config.env_vars = envVarsPtr
        config.env_var_count = envCount  // was: 1
```

Update the failure-cleanup block (inside the `guard let newSurface` else) to free the new pointers:

```swift
        guard let newSurface = ghostty_surface_new(app, &config) else {
            envVarsPtr.deinitialize(count: envCount)
            envVarsPtr.deallocate()
            free(cwdCStr)
            free(sockKey)
            free(sockVal)
            if let cmdCStr { free(cmdCStr) }
            if let zmxDirKey { free(zmxDirKey) }
            if let zmxDirVal { free(zmxDirVal) }
            Unmanaged<SurfaceUserdataBox>.fromOpaque(userdataPtr).release()
            fatalError("ghostty_surface_new returned null")
        }
```

And the success-path cleanup at the end of init:

```swift
        envVarsPtr.deinitialize(count: envCount)
        envVarsPtr.deallocate()
        free(cwdCStr)
        free(sockKey)
        free(sockVal)
        if let cmdCStr { free(cmdCStr) }
        if let zmxDirKey { free(zmxDirKey) }
        if let zmxDirVal { free(zmxDirVal) }
```

- [ ] **Step 2: Build to verify the surface compiles**

Run: `swift build`
Expected: compiles cleanly. (No new tests for this layer — it's a thin wrapper around the libghostty C API.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/SurfaceHandle.swift
git commit -m "$(cat <<'EOF'
feat(zmx): SurfaceHandle accepts zmxCommand + zmxDir

Adds optional zmxCommand (full `zmx attach <session> $SHELL` invocation)
and zmxDir parameters. When zmxCommand is non-nil, libghostty spawns
that instead of the default $SHELL; when zmxDir is non-nil, the
spawned process inherits ZMX_DIR. Both nil means pre-zmx behavior —
the fallback path when ZmxLauncher is unavailable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire `TerminalManager` and `EspalierApp` to use `ZmxLauncher`

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift` (add launcher; pass through to surfaces; call kill in destroy)
- Modify: `Sources/Espalier/EspalierApp.swift` (instantiate launcher, pass to manager)

- [ ] **Step 1: Add launcher to `TerminalManager`**

In `Sources/Espalier/Terminal/TerminalManager.swift`, add an import (if not present):

```swift
import EspalierKit
```

Add a stored property near the top of the class (after `private var surfaces`):

```swift
    /// Set by `EspalierApp` at startup. When non-nil and `isAvailable`,
    /// every new surface spawns `zmx attach <session> $SHELL` so the
    /// session survives Espalier quits. When nil or unavailable, surfaces
    /// fall back to libghostty's default $SHELL spawn.
    var zmxLauncher: ZmxLauncher?
```

Modify `createSurfaces(for:worktreePath:)` (around line 172). Replace the `SurfaceHandle(…)` construction to pass the zmx parameters:

```swift
            let zmxCommand: String?
            let zmxDir: String?
            if let launcher = zmxLauncher, launcher.isAvailable {
                let session = launcher.sessionName(for: terminalID)
                zmxCommand = launcher.attachCommand(sessionName: session)
                zmxDir = launcher.zmxDir.path
            } else {
                zmxCommand = nil
                zmxDir = nil
            }
            let handle = SurfaceHandle(
                terminalID: terminalID,
                app: app,
                worktreePath: worktreePath,
                socketPath: socketPath,
                zmxCommand: zmxCommand,
                zmxDir: zmxDir,
                terminalManager: self
            )
```

Apply the same transformation to `createSurface(terminalID:worktreePath:)` (around line 194).

Modify `destroySurfaces(terminalIDs:)` (around line 238). After the existing loop body, add the zmx kill:

```swift
    func destroySurfaces(terminalIDs: [TerminalID]) {
        for id in terminalIDs {
            surfaces[id]?.requestClose()
            surfaces.removeValue(forKey: id)
            titles.removeValue(forKey: id)
            killZmxSession(for: id)
        }
    }

    func destroySurface(terminalID: TerminalID) {
        surfaces[terminalID]?.requestClose()
        surfaces.removeValue(forKey: terminalID)
        titles.removeValue(forKey: terminalID)
        killZmxSession(for: terminalID)
    }

    /// Fire-off the `zmx kill` for a terminal's session. Dispatched off
    /// the main thread because subprocess wait can take tens of ms; we
    /// don't want to block UI. Result is intentionally ignored — kill of
    /// an already-gone session is the success outcome.
    private func killZmxSession(for terminalID: TerminalID) {
        guard let launcher = zmxLauncher, launcher.isAvailable else { return }
        let name = launcher.sessionName(for: terminalID)
        DispatchQueue.global(qos: .utility).async {
            launcher.kill(sessionName: name)
        }
    }
```

- [ ] **Step 2: Instantiate the launcher in `EspalierApp`**

In `Sources/Espalier/EspalierApp.swift`, the `TerminalManager` is constructed at line 33 inside `init()` as a `@StateObject` — we can't mutate it there. The right place to wire the launcher is `startup()` (line 121, called from `.onAppear`), where `terminalManager.initialize()` is already invoked.

Inside `startup()`, immediately *before* the existing `terminalManager.initialize()` line, insert:

```swift
        let zmxBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/zmx")
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let zmxDir = appSupport
            .appendingPathComponent("Espalier", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        let zmxLauncher = ZmxLauncher(executable: zmxBinary, zmxDir: zmxDir)
        terminalManager.zmxLauncher = zmxLauncher
```

`EspalierKit` is already imported at the top of the file (line 3), so no import addition needed.

- [ ] **Step 3: Build the bundle and smoke-test manually**

```bash
./scripts/bundle.sh
open .build/Espalier.app
```

In the app: add a worktree, type `echo MARKER`, quit Espalier (Cmd-Q), reopen `.build/Espalier.app`. Expected: the worktree comes back with `MARKER` visible in the scrollback. (If it doesn't survive, check `~/Library/Application\ Support/Espalier/zmx/` for socket files and run `ZMX_DIR=~/Library/Application\ Support/Espalier/zmx /Applications/Espalier.app/Contents/Helpers/zmx list` to inspect.)

- [ ] **Step 4: Run the full test suite to make sure nothing broke**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift Sources/Espalier/EspalierApp.swift
git commit -m "$(cat <<'EOF'
feat(zmx): TerminalManager spawns panes via zmx attach

Every new surface now spawns `zmx attach espalier-<short-id> $SHELL`
as its PTY child (when the bundled binary is available); destroy
fires `zmx kill` off the main thread. EspalierApp constructs the
ZmxLauncher pointing at Contents/Helpers/zmx and a private ZMX_DIR
under Application Support. Falls back to libghostty's default $SHELL
spawn when the binary is missing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Fallback banner when `zmx` is unavailable

**Files:**
- Create: `Sources/Espalier/Views/ZmxFallbackBanner.swift`
- Modify: `Sources/Espalier/EspalierApp.swift` (present banner once if launcher unavailable)

A non-blocking one-time alert. Don't keep nagging — once acknowledged, don't show again that session.

- [ ] **Step 1: Create the banner**

Create `Sources/Espalier/Views/ZmxFallbackBanner.swift`:

```swift
import AppKit

/// One-time non-blocking alert presented at app launch when the bundled
/// zmx binary is missing or unloadable. The user gets a "your terminals
/// won't survive quit" warning so the missing survival behavior doesn't
/// look like a silent regression.
///
/// State is process-local — re-launching the app re-presents the alert
/// if the binary is still missing.
enum ZmxFallbackBanner {

    private static var hasShown = false

    /// Present the banner if it hasn't been shown yet this process.
    /// Safe to call from any thread; hops to main if needed.
    @MainActor
    static func presentIfNeeded() {
        guard !hasShown else { return }
        hasShown = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "zmx unavailable"
        alert.informativeText = """
            Espalier couldn't load its bundled session-persistence helper. \
            Terminals will work, but they won't survive Espalier quitting.

            This usually means the app bundle was modified or wasn't \
            built with `scripts/bundle.sh`. Re-running the bundle script \
            normally restores the helper.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 2: Wire it into `EspalierApp`**

In `Sources/Espalier/EspalierApp.swift` `startup()`, just after the `terminalManager.zmxLauncher = zmxLauncher` line added in Task 7, add:

```swift
        if !zmxLauncher.isAvailable {
            DispatchQueue.main.async {
                ZmxFallbackBanner.presentIfNeeded()
            }
        }
```

The dispatch defers to the next runloop turn so the modal alert doesn't run during `.onAppear` (which can interfere with window presentation on macOS 14).

- [ ] **Step 3: Build and smoke test the fallback path**

```bash
./scripts/bundle.sh
mv .build/Espalier.app/Contents/Helpers/zmx{,.bak}
open .build/Espalier.app
```

Expected: the banner appears. Click OK; create a worktree; verify a shell still spawns and works (just won't survive quit).

Restore the binary:

```bash
mv .build/Espalier.app/Contents/Helpers/zmx{.bak,}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Views/ZmxFallbackBanner.swift Sources/Espalier/EspalierApp.swift
git commit -m "$(cat <<'EOF'
feat(zmx): one-time banner when zmx binary is unavailable

If Bundle.main's Contents/Helpers/zmx is missing or unloadable,
Espalier presents a single informational alert at launch explaining
that survival won't work, then continues with the libghostty
default-shell fallback (already wired in TerminalManager).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SPECS.md — append §13 zmx Session Backing

**Files:**
- Modify: `SPECS.md` (append after §12 Technology Constraints)

EARS-form requirements for Phase 1's behavior so future readers (and Phase 2/3 specs) have a concrete reference.

- [ ] **Step 1: Append the section**

Open `SPECS.md`. After the last line of §12 (the existing "Technology Constraints" section), append:

```markdown

## 13. zmx Session Backing

### 13.1 Bundling

**ZMX-1.1** The application shall include a `zmx` binary in the app bundle at `Espalier.app/Contents/Helpers/zmx`, mirroring the placement of the `espalier` CLI.

**ZMX-1.2** The bundled `zmx` binary shall be a universal Mach-O containing both `arm64` and `x86_64` slices, produced by `scripts/bump-zmx.sh`.

**ZMX-1.3** The application shall pin the vendored `zmx` version in `Resources/zmx-binary/VERSION` and record its SHA256 in `Resources/zmx-binary/CHECKSUMS`.

### 13.2 Session Naming

**ZMX-2.1** The application shall derive the zmx session name for each pane as the literal string `"espalier-"` followed by the lowercase hex of the first 8 bytes — i.e., the first 8 hex characters — of the pane's UUID.

**ZMX-2.2** The session-naming function shall be deterministic and shall not change across releases without an explicit migration step, since changing it orphans every existing user's daemons.

### 13.3 Sandboxing

**ZMX-3.1** The application shall pass `ZMX_DIR=~/Library/Application Support/Espalier/zmx/` in the environment of every spawned `zmx` invocation, so Espalier-owned daemons live in a private socket directory distinct from any user-personal `zmx` usage.

**ZMX-3.2** The application shall create the `ZMX_DIR` path if it does not exist at launch.

### 13.4 Lifecycle Mapping

**ZMX-4.1** When the application creates a new terminal pane, it shall set the libghostty surface configuration's `command` field to `'<bundled-zmx-path>' attach espalier-<short-id> $SHELL`, with the bundled-zmx-path single-quoted to defend against spaces in the install path.

**ZMX-4.2** When the application restores a worktree's split tree on launch (per `PERSIST-3.x`), each restored pane's surface shall be created with the same session name derived from the persisted pane UUID, so reattach to a surviving daemon is automatic.

**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.

**ZMX-4.4** When the application quits, it shall not invoke `zmx kill` — pending PTY teardown by the OS is the desired detach signal that lets daemons survive.

### 13.5 Fallback

**ZMX-5.1** If the bundled `zmx` binary is missing or not executable, the application shall fall back to libghostty's default `$SHELL` spawn behavior on a per-pane basis.

**ZMX-5.2** If the bundled `zmx` binary is unavailable at launch, the application shall present a single non-blocking informational alert explaining that terminals will not survive app quit. The alert shall not be re-presented within the same process lifetime.

### 13.6 Pass-through Guarantees

**ZMX-6.1** Shell-integration OSC sequences (OSC 7 working directory, OSC 9 desktop notification, OSC 133 prompt marks, OSC 9;4 progress reports) shall continue to flow from the inner shell through `zmx` to libghostty unchanged. The `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` requirements remain in force regardless of whether `zmx` is mediating the PTY.

**ZMX-6.2** The `ESPALIER_SOCK` environment variable shall continue to be set in the spawned shell's environment per `ATTN-2.4`. Because `zmx` inherits its child shell's env from the spawning process, this is satisfied by setting it on the libghostty surface as today.
```

- [ ] **Step 2: Commit**

```bash
git add SPECS.md
git commit -m "$(cat <<'EOF'
docs(specs): §13 zmx session backing — Phase 1 requirements

EARS-form requirements covering bundling, session naming, ZMX_DIR
sandboxing, lifecycle mapping (create / restore / destroy / quit),
fallback behavior when the binary is unavailable, and the OSC /
env-var pass-through guarantees that mean shell integration keeps
working through the zmx hop.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Manual smoke-test verification

This task is a **manual checklist** — no code changes. The plan's executor walks through each item and confirms.

- [ ] **Smoke 1: Survival across quit**

```bash
./scripts/bundle.sh
open .build/Espalier.app
```

In the app: add a repository, click into a worktree, type `echo HELLO_FROM_PRE_QUIT`, then Cmd-Q to quit. Reopen `.build/Espalier.app`. Expected: the worktree restores with `HELLO_FROM_PRE_QUIT` visible in the scrollback.

- [ ] **Smoke 2: External zmx visibility**

With Espalier closed, run:

```bash
ZMX_DIR=~/Library/Application\ Support/Espalier/zmx /Applications/Espalier.app/Contents/Helpers/zmx list 2>/dev/null \
  || ZMX_DIR=~/Library/Application\ Support/Espalier/zmx .build/Espalier.app/Contents/Helpers/zmx list
```

Expected: prints one line per surviving pane (`espalier-<short>` style names).

- [ ] **Smoke 3: Fallback path**

```bash
mv .build/Espalier.app/Contents/Helpers/zmx{,.bak}
open .build/Espalier.app
```

Expected: an alert appears explaining zmx is unavailable. Dismiss it; verify creating a new worktree still spawns a working shell. Quit; restore: `mv .build/Espalier.app/Contents/Helpers/zmx{.bak,}`.

- [ ] **Smoke 4: Stop kills sessions**

Reopen Espalier, create panes, then right-click the worktree row → Stop. Confirm. Then run smoke 2's `zmx list` invocation — those sessions should no longer appear.

If all four pass, Phase 1 is done.

---

## Notes for the Executor

- **The session-name function in `ZmxLauncher.sessionName(for:)` is a hard contract.** A unit test asserts a specific UUID maps to a specific session name. Don't change either side casually.
- **`zmx kill` is intentionally fire-and-forget from the UI's perspective.** The dispatch to `.utility` queue is load-bearing — without it, closing a pane would block the main thread for tens of ms while the subprocess returns.
- **`zmxCommand` and `zmxDir` are both optional in `SurfaceHandle.init`.** When nil, libghostty uses its default `$SHELL` spawn — that's the fallback path and it must continue to work end-to-end. Don't make these mandatory.
- **Tests can run on a contributor machine without zmx vendored.** The integration tests skip with a clear `try #require()` message, the unit tests use `/bin/sh` and `/bin/echo` (universally present), so `swift test` works after a clean clone.
- **Out of scope for this plan:** codesigning the bundled zmx for distribution, GitHub Actions auto-bump, launchd-supervised reboot survival, the WebSocket server, the web client. All deferred to later phases or release-time concerns.

# Runner Tailcat and Invites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every runner listens on Tailcat, the Mac reaches runners over Tailcat, and a runner can be added by pasting an invite it prints.

**Architecture:** Tailcat's Go C archive is built for Linux and linked into `graftty-runner`, as the xcframework is on the Mac. One shared listener loop in `GrafttyTailcat` hands accepted streams to `DirectSSHHostServer.accept(input:output:)` on both the Mac host and the runner. The Mac gains a `.tailcat` runner transport that dials the saved endpoint and runs the existing pinned SSH client over the stream. Invites carry the runner's identity, Tailcat endpoint, and a one-time secret; the Mac presents the secret in the SSH username during public-key authentication, and the runner enrolls the signing key.

**Tech Stack:** Swift 6 / SwiftPM, SwiftNIO SSH, Tailcat C archive (Go, `-buildmode=c-archive`), bash packaging, GitHub Actions in `swift:6.4.2-noble`.

**Spec:** `docs/superpowers/specs/2026-11-23-remote-runner-setup-design.md` (sections "Tailcat in the runner", "Connecting from the Mac", "Two ways in", "Updating and existing runners", "Delivery").

## Global Constraints

- Public open-source project: no keys, Tailcat addresses, invites, or secrets in commits, fixtures, logs, or error text. Fixtures generate identities at test time.
- A Tailcat address or invite never appears in logs, error text, or the saved host list (`RemoteMac` JSON). Types holding them redact `description` and `debugDescription`.
- Tailcat is pinned by `Prototypes/Tailcat/UPSTREAM_COMMIT` (`e00cdde6ff787f801361ff85ed085775c775d4c5`) for both Apple and Linux builds.
- Keychain stays on Apple platforms. Linux credentials live in a `0600` file under the runner's state directory.
- The runner always listens on Tailcat; `TailcatPreference` does not gate runner listening or runner dialing.
- No direct-port fallback for a runner whose transport is `.tailcat`.
- New systemd installs bind SSH and HTTP to `127.0.0.1`. `--maintenance` keeps the existing unit's bind address. The container keeps `--bind-address 0.0.0.0` inside its namespace.
- Invites are printed only by `graftty-runner invite`, or once at first start when `GRAFTTY_PRINT_INVITE=1` and no peer is trusted.
- Requirements use `@spec` EARS titles, new IDs under `REMOTE-33.x` (runner over Tailcat) and `DIST-4.16+` (packaging). No literal quotes in titles. Regenerate `SPECS.md` with `scripts/generate-specs.py`.
- Local builds and tests go through `scripts/swiftpm`; never `--skip-build`. Linux checks run in `swift:6.4.2-noble` with `--platform linux/arm64` natively (Zig crashes under Rosetta); x86_64 is verified in CI.
- Never add to `linuxPendingKitTests`.
- Run `/code-review xhigh --fix` before opening the PR.

## Review Focus

1. **Signature before enrollment.** An SSH client that sends an enrollment username with an *unsigned* public-key query, or a signature from a different key, must not enroll anything. Task 4 pins this with a test that sends the query form and a mismatched key.
2. **Invite replay and expiry.** A second redemption of the same invite, or one after its hour, is refused and leaves the trusted-peer store unchanged. Task 4.
3. **Runner restart.** The Tailcat address survives `systemctl --user restart`; a Mac saved before the restart reconnects without re-adding. Task 2 (state reload) and Task 3 (restart in the smoke test).
4. **Old runner, new Mac.** A Mac adding an archive that predates Tailcat (no `tailcatEndpoint` in `trust-client` output) records `.directSSH` exactly as today. Task 6.
5. **Secrets in output.** `graftty-runner status --json`, service logs, and every thrown error omit the address and secret. Task 3 and Task 4 assert on rendered strings.

---

### Task 1: Gate — Tailcat linked into the Linux runner, relay proven

Work stops after this task if the link or the relay test fails on either architecture; report to the project owner for the Go-sidecar-or-direct-fallback decision.

**Files:**
- Create: `scripts/build-tailcat-linux` (builds `libtailcat.a` and `tailcat.h` for the host architecture)
- Create: `scripts/linux/install-go.sh`, `deps/go/VERSION`, `deps/go/checksums` (bootstrap Go 1.25.6 for linux-amd64/arm64, SHA-256 verified, like `install-zig.sh`)
- Create: `Sources/CTailcatLinux/module.modulemap` (`module CTailcat { header "../../.deps/tailcat-linux/tailcat.h"; link "tailcat"; export * }`)
- Modify: `scripts/deps` (`prepare_tailcat` on Linux calls `build-tailcat-linux`, caches by key of pin + script + Go version, links `.deps/tailcat-linux/`; drop the Darwin-only guard at line 436)
- Modify: `Package.swift` (Linux `tailcatTargets`: `.systemLibrary(name: "CTailcat", path: "Sources/CTailcatLinux")` plus `GrafttyTailcat` with `-L<repo>/.deps/tailcat-linux` unsafe linker flag; `fatalError` naming `scripts/deps prepare tailcat` when `libtailcat.a` is missing; `GrafttyRunner` gains `tailcatDependencies` on both platforms)
- Modify: `Sources/GrafttyTailcat/TailcatTransport.swift` (Glibc import, `SOCK_STREAM.rawValue`, `SHUT_RDWR` cast, no `SO_NOSIGPIPE` on Linux; bridge writes use `send(..., MSG_NOSIGNAL)` on Linux)
- Modify: `Sources/GrafttyTailcat/TailcatCredentials.swift` (whole file `#if canImport(Security)`)
- Modify: `.github/workflows/linux.yml` (install Go, cache the Tailcat build, `scripts/deps prepare tailcat` before tests, relay step below)
- Modify: `scripts/linux/package.sh` (prepare Tailcat before `swift build`)
- Test: `Tests/GrafttyRunnerTests/RunnerTailcatLinkTests.swift`

**Interfaces:**
- Produces: `import GrafttyTailcat` compiles on Linux; `TailcatPeer`, `TailcatListener`, `TailcatPipe`, `TailcatServerIdentity` unchanged in API.

- [ ] **Step 1: Write the failing test** — `@spec REMOTE-33.1: When the runner is built for Linux, the application shall carry a Tailcat byte stream between a server and a client peer in the runner process.` Start `TailcatPeer.server(identity: .generate())`, `listen(port: 8801)`, read `address()`, `TailcatPeer.client(address:)`, `dial(port: 8801)`, accept on the listener, write 1 MiB of patterned bytes through the client pipe's `file`, read them back from the accepted pipe, `#expect` equality. When `GRAFTTY_TAILCAT_REQUIRE_RELAY=1`, `#expect(try await client.routeKind() == "relay")`. `.timeLimit(.minutes(2))`.
- [ ] **Step 2: Run it on Linux arm64 to see it fail** — in the arm64 container: `swift test --filter RunnerTailcatLinkTests`. Expected: build failure, `no such module 'GrafttyTailcat'`.
- [ ] **Step 3: Build the archive, port the sources, wire the package** (files above).
- [ ] **Step 4: Run with forced relay on arm64** — `scripts/deps prepare tailcat && TS_DEBUG_ALWAYS_USE_DERP=true GRAFTTY_TAILCAT_REQUIRE_RELAY=1 swift test --filter RunnerTailcatLinkTests`. Expected: PASS, route `relay`.
- [ ] **Step 5: Link the real binary** — `scripts/linux/package.sh ci-gate dist` in arm64, then `scripts/linux/smoke-test.sh dist/graftty-linux-ci-gate-aarch64.tar.gz`. Expected: smoke passes, `graftty-runner --help` runs on stock Ubuntu (Tailcat is static, so `bundle-libraries` adds nothing new; check `ldd`).
- [ ] **Step 6: macOS unaffected** — `scripts/swiftpm test --filter GrafttyTailcatTests`. Expected: PASS.
- [ ] **Step 7: Commit, push to a branch, and confirm both CI Linux jobs (x86_64 and arm64) pass the relay step** — the CI step: `TS_DEBUG_ALWAYS_USE_DERP=true GRAFTTY_TAILCAT_REQUIRE_RELAY=1 swift test --no-parallel --filter RunnerTailcatLinkTests`. Expected: both jobs green. **If either architecture fails to link or to relay, stop and report.**

```bash
git commit -m "Build Tailcat for Linux and link it into the runner"
```

### Task 2: One Tailcat listener loop for the Mac host and the runner

**Files:**
- Create: `Sources/GrafttyTailcat/TailcatSSHListener.swift`
- Create: `Sources/GrafttyTailcat/TailcatListenerStateFile.swift` (Linux and Apple; `0600`, atomic write, parent `0700`)
- Modify: `Sources/Graftty/App/TailcatMacHost.swift` (uses `TailcatSSHListener` with a Keychain-backed store; behavior unchanged)
- Test: `Tests/GrafttyRunnerTests/TailcatListenerStateFileTests.swift`, `Tests/GrafttyRunnerTests/TailcatSSHListenerTests.swift`

**Interfaces:**
- Produces:
  - `public struct TailcatListenerState: Codable, Sendable { identity: TailcatServerIdentity; address: String }` (redacted descriptions)
  - `public protocol TailcatListenerStateStore: Sendable { func load() throws -> TailcatListenerState?; func save(_: TailcatListenerState) throws }`
  - `public struct TailcatListenerStateFile: TailcatListenerStateStore { init(url: URL) }`
  - `public actor TailcatSSHListener { init(store: some TailcatListenerStateStore, port: UInt16, accept: @escaping @Sendable (FileHandle) async throws -> @Sendable () async -> Void); func start() async throws -> TailcatEndpoint; func stop() async; var endpoint: TailcatEndpoint? { get } }` — `accept` receives the pipe's file, returns a waiter that completes when the SSH connection closes; the loop closes `file` after `accept` returns and closes the pipe after the waiter.

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.2: When the runner saves its Tailcat listener state, the application shall write it to a file readable only by its owner.` — save, `#expect` POSIX permissions `0o600`, load round-trips identity and address, file contents not in `String(describing: state)`.
  - `@spec REMOTE-33.3: When the Tailcat listener restarts with saved state, the application shall keep the same Tailcat address.` — start with a temp `TailcatListenerStateFile`, record `endpoint`, `stop()`, start a new listener on the same file, `#expect` equal address. Network test, `.timeLimit(.minutes(2))`.
- [ ] **Step 2: Run, expect compile failure** — `scripts/swiftpm test --filter TailcatListener`.
- [ ] **Step 3: Implement** the types; move the loop body from `TailcatMacHost.update()` into `TailcatSSHListener`; `TailcatMacHost` keeps its preference observer and supplies a Keychain store wrapping `TailcatCredentials.load/save` with account `"listener-" + fingerprint.display`.
- [ ] **Step 4: Run** — `scripts/swiftpm test --filter "TailcatListener|GrafttyTailcatTests"`, then the same filter on Linux arm64. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Share one Tailcat SSH listener between the Mac host and the runner"`

### Task 3: The runner listens on Tailcat and reports its endpoint

**Files:**
- Modify: `Sources/GrafttyRunner/HostService.swift` (start `TailcatSSHListener` with `TailcatListenerStateFile(url: configuration.identityDirectory/"tailcat-listener.json")` and `ssh.accept(input:output:)`; stop it on shutdown; a listener failure is logged without detail and retried with backoff, never fatal to `serve`; `signal(SIGPIPE, SIG_IGN)` at startup)
- Modify: `Sources/GrafttyKit/Host/HeadlessHostControl.swift:89` (answer `.tailcatEndpoint` from an injected `@Sendable () async -> TailcatEndpoint?`)
- Modify: `Sources/GrafttyKit/Host/HostAdministration.swift` (`HostAdminRequest.tailcatEndpoint`, response `.tailcatEndpoint(TailcatEndpoint?)`; `HostStatus` gains `tailcat: Bool` — listening or not, never the address)
- Modify: `Sources/GrafttyRunner/GrafttyRunner.swift` (`trust-client` output gains `tailcatEndpoint`, fetched from the admin socket, waiting up to 30 s for the listener; absent if the service is not running)
- Modify: `Sources/GrafttyKit/HostSetup/LinuxHostIdentity.swift` (`public let tailcatEndpoint: TailcatEndpoint?`, decoded with `decodeIfPresent`)
- Modify: `Sources/GrafttyKit/HostSetup/LinuxHostScripts.swift:78` (fresh install passes `--bind-address 127.0.0.1`)
- Modify: `scripts/linux/smoke-test.sh` (after `start_host`: `status --json` shows `"tailcat":true`; restart and `trust-client` returns the same endpoint address — compared in-shell, never printed)
- Test: `Tests/GrafttyRunnerTests/RunnerTailcatServeTests.swift`, `Tests/GrafttyKitTests/HostSetup/LinuxHostSetupTests.swift`

**Interfaces:**
- Consumes: `TailcatSSHListener`, `TailcatListenerStateFile` (Task 2).
- Produces: `LinuxHostIdentity.tailcatEndpoint`; `HostAdminRequest.tailcatEndpoint`; `HostStatus.tailcat`.

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.4: While the runner is serving, the application shall accept paired SSH sessions over Tailcat.` — start `HostService` on loopback in a temp state dir, trust a generated client key with `HostService.trust`, read the endpoint over the admin socket, dial with `TailcatPeer.client` and `DirectSSHHostConnection.connect(input:output:)`, open a pane-control client, `#expect(.ok)` for `.equalize`.
  - `@spec REMOTE-33.5: When a worktree-management client asks a runner for its Tailcat endpoint, the application shall return the endpoint it is listening on.`
  - `@spec REMOTE-33.6: The runner status output shall report whether Tailcat is listening without including its address.` — encode `HostStatus`, `#expect` no `address` key.
  - `@spec REMOTE-21.30: When setting up a new runner, the application shall bind its SSH and HTTP listeners to loopback.` — the generated install script contains `--bind-address 127.0.0.1` and not `0.0.0.0`.
  - `LinuxHostIdentity` decodes JSON without `tailcatEndpoint` (old runner) to `nil`.
- [ ] **Step 2: Run, expect failures** — `scripts/swiftpm test --filter "RunnerTailcatServe|LinuxHostSetupTests"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** on macOS and Linux arm64; then package and run `scripts/linux/smoke-test.sh` on arm64. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Serve the runner over Tailcat and report its endpoint"`

### Task 4: Runner invites and enrollment by invite

**Files:**
- Create: `Sources/GrafttyKit/HostSetup/RunnerInvite.swift`
- Create: `Sources/GrafttyHostAgent/SSH/InviteEnrollment.swift`
- Modify: `Sources/GrafttyHostAgent/SSH/SSHUserAuthDelegate.swift` (optional `enroll` hook for a signed public-key request from an unknown key whose username starts with `RunnerEnrollmentToken.prefix`)
- Modify: `Sources/GrafttyHostAgent/DirectSSHHostServer.swift` (`setInviteEnrollment(_:)`)
- Modify: `Sources/GrafttyRunner/HostService.swift` (in-memory `RunnerInviteBook`; admin `.createInvite`; first-start print when `GRAFTTY_PRINT_INVITE=1` and `TrustedPeerStore` is empty, to stdout only)
- Modify: `Sources/GrafttyRunner/GrafttyRunner.swift` (`Invite` subcommand printing one line; error if the service is not running)
- Modify: `Sources/GrafttyKit/Host/HostAdministration.swift` (`.createInvite` → `.invite(RunnerInvite)`)
- Test: `Tests/GrafttyKitTests/HostSetup/RunnerInviteTests.swift`, `Tests/GrafttyRunnerTests/InviteEnrollmentTests.swift`

**Interfaces:**
- Consumes: `LinuxHostIdentity`, `LinuxHostTrustRequest`, `HostService.trust` (existing); endpoint from Task 3.
- Produces:
  - `public struct RunnerInvite: Codable, Sendable, Equatable { identity: LinuxHostIdentity; endpoint: TailcatEndpoint; secret: Data; expiresAt: Date; static let prefix = "graftty-invite-1:"; func encoded() -> String; init(parsing: String) throws }` — encoding is the prefix plus base64url (no padding) of sorted-key JSON; `init(parsing:)` trims whitespace, rejects a missing prefix, bad base64, or a non-32-byte secret with `RunnerInviteError.malformed`; descriptions redacted.
  - `public struct RunnerEnrollmentToken: Codable, Sendable { secret: Data; deviceID: String; displayName: String; static let prefix = "graftty-enroll-1:"; var username: String; init(username: String) throws }`
  - `public final class RunnerInviteBook: Sendable { init(now: @escaping @Sendable () -> Date); func issue(lifetime: Duration = .seconds(3600)) -> Data; func redeem(_ secret: Data) -> Bool }` — stores SHA-256 of each secret, compares in constant time, removes on success and on expiry.
  - `DirectSSHHostConnection` init gains `username: String` with the current value as default.

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.7: When a runner invite is encoded and parsed, the application shall recover the runner identity, Tailcat endpoint, secret, and expiry.` — plus malformed inputs (no prefix, truncated, 31-byte secret) throw, and `String(describing:)` contains no secret or address.
  - `@spec REMOTE-33.8: When a Mac presents an unexpired invite secret while signing with its key, the runner shall trust that key and accept the session.` — `InviteEnrollmentTests` over loopback `DirectSSHHostServer` (no Tailcat needed): issue, connect with `username: token.username`, session opens; reconnect with the default username succeeds; `TrustedPeerStore` holds the key with the token's device ID and name.
  - `@spec REMOTE-33.9: If an invite secret was already redeemed or has expired, then the runner shall refuse enrollment and leave its trusted peers unchanged.` — second redemption fails; injected clock past expiry fails.
  - `@spec REMOTE-33.10: If an enrollment request is not signed by the presented key, then the runner shall not enroll it.` — drive `SSHUserAuthDelegate.requestReceived` with a public-key request lacking a valid signature (NIOSSH's query form) and assert rejection with the store unchanged. If NIOSSH only calls the delegate after verifying the signature, record that with a test proving the query form never reaches `enroll`.
  - `@spec REMOTE-33.11: When asked for an invite, the runner shall print one invite line and nothing else.` — `graftty-runner invite --runtime-directory …` against a running test service; stdout is one line with the prefix.
  - `@spec REMOTE-33.12: When GRAFTTY_PRINT_INVITE is 1 and no peer is trusted, the runner shall print one invite at start.`
- [ ] **Step 2: Run, expect failures** — `scripts/swiftpm test --filter "RunnerInvite|InviteEnrollment"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** on macOS and Linux arm64. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add runner invites and one-time enrollment by invite"`

### Task 5: The Mac reaches runners over Tailcat

**Files:**
- Modify: `Sources/GrafttyKit/Remote/MacToMac/RemoteMac.swift:118` (`RemoteHostTransport.tailcat`)
- Create: `Sources/GrafttyRemoteClient/Remote/TailcatRunnerDialer.swift` (`#if canImport(GrafttyTailcat)`)
- Modify: `Sources/Graftty/Remote/MacToMac/RemoteMacConnectionRegistry.swift:465-530` (`DialLink.tailcat`; endpoint from `TailcatCredentials.endpoint(for:)`; missing endpoint or dial failure → `ConnectionError.runnerUnreachable(identity)`; the entry retains and closes the dialed stream; after a `.directSSH` runner connects, send `.tailcatEndpoint`, and on a non-nil reply save it and switch the saved transport to `.tailcat`)
- Modify: `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift` (`setTransport(_:for:)` used by the migration)
- Test: `Tests/GrafttyTests/Remote/RunnerTailcatTransportTests.swift`

**Interfaces:**
- Consumes: `TailcatEndpoint`, `TailcatCredentials.endpoint(for:)/saveEndpoint(_:for:)`.
- Produces: `public final class TailcatDialedStream: Sendable { static func connect(_ connection: DirectSSHHostConnection, endpoint: TailcatEndpoint) async throws -> TailcatDialedStream; func close() async }`; `RemoteHostTransport.tailcat`; registry factory seam `tailcatDialer: @Sendable (DirectSSHHostConnection, TailcatEndpoint) async throws -> TailcatDialedStream` for tests.

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.13: When a saved runner uses Tailcat, the application shall dial its saved Tailcat endpoint and pin the runner key over that stream.` — fake dialer records the endpoint; registry reaches connected.
  - `@spec REMOTE-33.14: If a Tailcat runner cannot be dialed, then the application shall report it unreachable without trying another transport.` — fake dialer throws; the direct factory is never called.
  - `@spec REMOTE-33.15: When a direct-SSH runner reports a Tailcat endpoint, the application shall save it and use Tailcat for later connections.`
  - `RemoteMac` with `.tailcat` round-trips through JSON; an old JSON without the case still decodes `.directSSH`.
- [ ] **Step 2: Run, expect failures** — `scripts/swiftpm test --filter RunnerTailcatTransport`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `scripts/swiftpm test --filter "RunnerTailcatTransport|RemoteMacConnectionRegistry"`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Connect to runners over Tailcat and move direct runners to it"`

### Task 6: SSH setup saves a Tailcat runner

**Files:**
- Modify: `Sources/Graftty/HostSetup/LinuxHostSetupConnectionController.swift:15-40` (identity with `tailcatEndpoint` → save to Keychain, record `.tailcat`; without → `.directSSH` as today)
- Modify: `Sources/Graftty/Views/MainWindow.swift:1338` (Tailcat failure says the runner is installed and paired but not reachable over Tailcat, no firewall or port text)
- Modify: `Sources/Graftty/Views/LinuxHostSetupSheet.swift` and `Sources/Graftty/Views/LinuxHostMaintenanceSheet.swift:40` (drop the port 8801 wording)
- Modify: `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift:1814` and `Sources/Graftty/Views/LinuxHostMaintenanceSheet.swift:104` (**Update Runner…** eligibility keys on a saved `maintenanceDestination`, not on `directEndpoint`, so SSH-installed Tailcat runners keep it and invite-added runners never show it)
- Test: `Tests/GrafttyTests/HostSetup/LinuxHostSetupConnectionTests.swift` (existing file if present, else create)

**Interfaces:**
- Consumes: `LinuxHostIdentity.tailcatEndpoint` (Task 3), `RemoteHostTransport.tailcat` (Task 5).

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.16: When SSH setup finishes on a runner that reports a Tailcat endpoint, the application shall save the runner with the Tailcat transport and keep its OpenSSH destination for updates.`
  - `@spec REMOTE-33.17: When SSH setup finishes on a runner that reports no Tailcat endpoint, the application shall save it with direct SSH.`
  - Update `REMOTE-22.26` (Update Runner eligibility) to: offered for a connected Linux runner with a saved OpenSSH destination, whatever its transport; add cases for a `.tailcat` runner with and without a destination.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `scripts/swiftpm test --filter LinuxHostSetup`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Save SSH-installed runners with their Tailcat endpoint"`

### Task 7: Redeem an invite from the CLI

**Files:**
- Modify: `Sources/GrafttyProtocol` control request enum (where `.linuxSetupIdentity` lives): `.redeemRunnerInvite(String)` → `.runnerAdded(displayName: String)`
- Create: `Sources/Graftty/HostSetup/RunnerInviteRedemption.swift` (parse, dial over Tailcat with `expectedHostFingerprint` from the invite's public key and `username: RunnerEnrollmentToken(...).username`, close, save `PinnedHost` and `RemoteMac(.tailcat)`, save endpoint, request a connection)
- Modify: `Sources/GrafttyCLI/RemoteSetupLinux.swift` (when the destination argument parses as a `RunnerInvite`, send `.redeemRunnerInvite` instead of SSH setup; other flags are then rejected)
- Test: `Tests/GrafttyTests/HostSetup/RunnerInviteRedemptionTests.swift`, `Tests/GrafttyCLITests/RemoteSetupLinuxCLITests.swift`

**Interfaces:**
- Consumes: `RunnerInvite`, `RunnerEnrollmentToken` (Task 4); `TailcatDialedStream` (Task 5); `RemoteMacsModel.recordPairingResult(_:transport:directEndpoint:maintenanceDestination:)`.

- [ ] **Step 1: Failing tests**
  - `@spec REMOTE-33.18: When the user adds a runner with an invite, the application shall enroll over Tailcat, pin the invite key, and save the runner with the Tailcat transport and no OpenSSH destination.` — fake dialer; saved `RemoteMac` has `.tailcat`, `maintenanceDestination == nil`.
  - `@spec REMOTE-33.19: When an invite names a runner already saved with the same key, the application shall replace the saved entry.`
  - `@spec REMOTE-33.20: If the runner presents a key other than the invite key, then the application shall abort without saving.`
  - `@spec REMOTE-21.31: When graftty remote add-runner receives an invite, the CLI shall redeem it through the running app.` — parsing test only; any error text excludes the invite.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `scripts/swiftpm test --filter "RunnerInviteRedemption|RemoteSetupLinuxCLI"`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add a runner from an invite with graftty remote add-runner"`

### Task 8: Container, docs, and end-to-end check

**Files:**
- Modify: `scripts/linux/runner/Dockerfile` (drop `EXPOSE`, drop `--enable-pairing` from `CMD`)
- Modify: `scripts/linux/runner/smoke-test.sh` (`docker exec … graftty-runner invite` prints one line with the prefix; `status` shows `"tailcat":true`)
- Modify: `docs/remote-runner.md` (container section: `docker run` without `--publish`, `docker exec graftty-runner graftty-runner invite`, `graftty remote add-runner '<invite>'`, `GRAFTTY_PRINT_INVITE=1`; SSH install: no inbound port needed beyond OpenSSH; updating: existing installs keep their port and move to Tailcat on reconnect)
- Modify: `README.md` if it mentions ports 8800/8801 for runners
- Test: `scripts/linux/runner/smoke-test.sh`

- [ ] **Step 1: Update the smoke test first and run it against the Task 7 image** — expect failure on the `EXPOSE`/`tailcat` assertions until the Dockerfile changes.
- [ ] **Step 2: Change the Dockerfile and docs.**
- [ ] **Step 3: Run the runner smoke on arm64.** Expected: PASS.
- [ ] **Step 4: End-to-end, forced relay** — run the arm64 runner image with `-e TS_DEBUG_ALWAYS_USE_DERP=true` and no published ports, get an invite with `docker exec`, and on the Mac run `TS_DEBUG_ALWAYS_USE_DERP=true graftty remote add-runner '<invite>'` against a dev instance (see the isolated dev instance memory). Expected: the runner appears under Remote Hosts, connected; a pane opens. Do not paste the invite into any file or log.
- [ ] **Step 5: Regenerate specs and run everything** — `scripts/generate-specs.py`, `scripts/swiftpm test`, `uv run scripts/linux/test-packaging.py`, `uv run scripts/check-linux-test-allowlist.py`, and the Linux arm64 `swift test --no-parallel`. Expected: all pass, apart from the four machine-specific macOS failures known to pass in CI (CHROME-5.1, CHROME-5.2, LAYOUT-2.181, PROJECT-1.2).
- [ ] **Step 6: Commit** — `git commit -m "Run the runner container without published ports and document invites"`

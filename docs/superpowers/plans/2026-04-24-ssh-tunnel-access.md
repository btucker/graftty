# SSH Tunnel Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a testable v1 SSH tunnel access path: Mac serves Graftty over loopback HTTP, Mobile can model SSH hosts and generate/share an app public key, and another Mac can connect with a manual SSH tunnel.

**Architecture:** Keep Tailscale mode unchanged. Add an access mode setting that lets `WebServerController` build either the existing HTTPS/Tailscale server or a new HTTP loopback-only server. On Mobile, extend host persistence with a transport enum and add focused SSH key/onboarding primitives; the actual direct-tcpip tunnel uses seams introduced here but can be completed with a dedicated SSH library task.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Testing, SwiftNIO HTTP/WebSocket, NIOSSL for Tailscale mode, CryptoKit/Security for generated mobile keys.

---

### Task 1: Mac Web Server Transport Mode

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift`
- Modify: `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift`
- Create: `Tests/GrafttyKitTests/Web/WebServerTransportTests.swift`

- [x] **Step 1: Write failing tests**
  - Add tests that `plainHTTPLoopbackOnly` accepts `127.0.0.1`, rejects non-loopback binds, and serves `/` without TLS.

- [x] **Step 2: Run tests to verify failure**
  - Run: `swift test --filter WebServerTransportTests`
  - Expected: compile failure because `WebTransportSecurity` / plain server support does not exist.

- [x] **Step 3: Implement minimal transport option**
  - Add `WebServer.TransportSecurity`.
  - Keep current initializer source-compatible by accepting `tlsProvider` and internally setting `.tls`.
  - Add a new initializer that accepts `transportSecurity`.
  - In `start()`, install `NIOSSLServerHandler` only for `.tls`.
  - Validate `.plainHTTPLoopbackOnly` binds only loopback addresses.

- [x] **Step 4: Run tests**
  - Run: `swift test --filter WebServerTransportTests`
  - Expected: pass.

### Task 2: Mac Access Mode Settings And Controller

**Files:**
- Modify: `Sources/Graftty/Web/WebAccessSettings.swift`
- Modify: `Sources/Graftty/Web/WebServerController.swift`
- Modify: `Sources/Graftty/Web/WebSettingsPane.swift`
- Create: `Tests/GrafttyKitTests/Web/WebAccessModeTests.swift` if settings can be tested outside the app target; otherwise cover pure formatting/helpers in existing tests.

- [x] **Step 1: Write failing tests where target boundaries allow**
  - Add pure tests for loopback URL/status composition and access mode raw values.

- [x] **Step 2: Implement settings**
  - Add `WebAccessMode: String, CaseIterable, Identifiable`.
  - Persist `modeRawValue` with `@AppStorage`.
  - Include mode in `WebServerController.lastApplied`.

- [x] **Step 3: Implement controller branch**
  - Tailscale branch remains current behavior.
  - SSH branch validates port, builds plain loopback server, uses loopback auth, skips Tailscale/certs/renewer, and sets `serverHostname = nil`.

- [x] **Step 4: Update settings UI**
  - Add Picker for mode.
  - Show mode-specific footer/status help.
  - Show Mac-to-Mac manual tunnel commands in SSH mode.
  - Hide Tailscale QR/base URL behavior in SSH mode; show `http://127.0.0.1:<port>/`.

- [x] **Step 5: Run focused tests**
  - Run: `swift test --filter WebServerTransportTests`
  - Run: `swift test --filter WebServerAuthTests`

### Task 3: Mobile Host Transport Model

**Files:**
- Modify: `Sources/GrafttyMobileKit/Hosts/Host.swift`
- Modify: `Sources/GrafttyMobileKit/Hosts/HostStore.swift`
- Modify: `Sources/GrafttyMobileKit/Hosts/HostPickerView.swift`
- Modify: `Sources/GrafttyMobileKit/Hosts/AddHostView.swift`
- Modify: `Tests/GrafttyMobileKitTests/Hosts/HostStoreTests.swift`

- [x] **Step 1: Write failing compatibility tests**
  - Decode legacy direct-HTTP host JSON.
  - Encode/decode SSH host config.
  - Verify URL dedupe only applies to direct HTTP hosts.

- [x] **Step 2: Implement transport enum**
  - Add `HostTransport` with `.directHTTP(baseURL:)` and `.sshTunnel(SSHHostConfig)`.
  - Keep `Host.baseURL` as a computed compatibility property for direct HTTP callers where possible.
  - Update store dedupe.

- [x] **Step 3: Update UI minimally**
  - Existing QR/manual URL flow creates direct HTTP hosts.
  - Host rows display URL for direct hosts and `user@host:port` for SSH hosts.

- [x] **Step 4: Run mobile host tests**
  - Run: `xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' test`

### Task 4: Mobile Generated SSH Public Key Scaffolding

**Files:**
- Create: `Sources/GrafttyMobileKit/SSH/MobileSSHKeyStore.swift`
- Create: `Sources/GrafttyMobileKit/SSH/SSHOnboardingInstructions.swift`
- Create: `Tests/GrafttyMobileKitTests/SSH/MobileSSHKeyStoreTests.swift`
- Create: `Tests/GrafttyMobileKitTests/SSH/SSHOnboardingInstructionsTests.swift`

- [x] **Step 1: Write failing tests**
  - Generated public key begins with supported SSH key prefix.
  - Repeated load returns stable public key.
  - Instructions include `authorized_keys` and the public key.

- [x] **Step 2: Implement key store**
  - Use a protocol-backed storage seam for tests.
  - Use Keychain-backed storage in production.
  - Generate a Secure Enclave-independent P-256 signing key if Ed25519 support is not available in standard Apple frameworks.

- [x] **Step 3: Implement instructions**
  - Produce copyable shell snippets for downloaded file and manual paste.

- [x] **Step 4: Run SSH mobile tests**
  - Run: `xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' test`

### Task 5: Verification

**Files:**
- All touched files.

- [x] **Step 1: Run focused suites**
  - Run: `swift test --filter WebServerTransportTests`
  - Run: `swift test --filter WebServerAuthTests`
  - Run: `swift test --filter HostStoreTests`
  - Run: `swift test --filter MobileSSHKeyStoreTests`
  - Run: `swift test --filter SSHOnboardingInstructionsTests`

- [x] **Step 2: Run broad build/tests as feasible**
  - Run: `swift test`
  - If full suite is too slow or blocked by environment, report the exact blocker.

- [x] **Step 3: Commit**
  - Commit implementation and tests.

# Mac Remote Hosts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Mac app add remote Macs running Graftty over SSH, group repositories by host when needed, and keep the current local-only sidebar unchanged.

**Architecture:** Add a host layer to `AppState`, migrate existing repositories to the implicit local host, and make remote hosts resolve to a runtime loopback URL through a managed `ssh -L` tunnel. Keep repository/worktree UI mostly path-based for local repos, but introduce host-scoped repository grouping and remote API fetch/update paths so remote host data can be displayed without pretending remote paths are local filesystem paths.

**Tech Stack:** Swift 5.10/6, SwiftUI, AppKit `NSAlert` / `NSOpenPanel`, `Process` for system `ssh`, existing Graftty web API fetchers, XCTest/Swift Testing.

---

## File Structure

Create:

- `Sources/GrafttyKit/Hosts/MacHost.swift` — Codable host model, local host identity, SSH config, display helpers.
- `Sources/GrafttyKit/Hosts/HostRepositorySnapshot.swift` — host-scoped cached repo/worktree snapshot used by sidebar rendering.
- `Sources/GrafttyKit/Hosts/MacHostStore.swift` — pure AppState helpers for host add/remove/update and migration.
- `Sources/GrafttyKit/Hosts/SSHLocalForward.swift` — system `ssh` local-forward process wrapper and tunnel lifecycle.
- `Sources/GrafttyKit/Hosts/RemoteGrafttyClient.swift` — fetch remote repos/worktrees via HTTP from a resolved tunnel base URL.
- `Sources/Graftty/Views/AddHostSheet.swift` — SwiftUI sheet for host details and test connection.
- `Tests/GrafttyKitTests/Hosts/MacHostTests.swift`
- `Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift`
- `Tests/GrafttyKitTests/Hosts/SSHLocalForwardTests.swift`
- `Tests/GrafttyKitTests/Hosts/RemoteGrafttyClientTests.swift`

Modify:

- `Sources/GrafttyKit/Model/AppState.swift` — add `hosts`, `repoHostAssignments`, selected host/worktree tracking, Codable migration.
- `Sources/GrafttyKit/Model/RepoEntry.swift` — optionally add `hostID` if a direct field proves simpler than an assignment map. Prefer assignment map first to reduce churn in existing repo tests.
- `Sources/Graftty/Views/SidebarView.swift` — render single-host flat list vs multi-host section headers; add `Add Host` action.
- `Sources/Graftty/Views/MainWindow.swift` — own Add Host sheet state, host selection, remote refresh/test paths, and keep `Add Repository` scoped to local/current host.
- `Sources/Graftty/GrafttyApp.swift` — start/stop remote tunnels on app lifecycle and persist changed host state.
- `Sources/Graftty/Web/WebSettingsPane.swift` — update Mac-to-Mac copy to point users at `Add Host` in the Mac app once available.

Avoid:

- Do not make remote repositories look like local filesystem repos in `WorktreeMonitor`.
- Do not run local git discovery against remote paths.
- Do not generate or import SSH keys on Mac.

---

## Task 1: Add Host Model And AppState Migration

**Files:**
- Create: `Sources/GrafttyKit/Hosts/MacHost.swift`
- Modify: `Sources/GrafttyKit/Model/AppState.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostTests.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift`

- [ ] **Step 1: Write failing host model tests**

Add tests covering local host identity, SSH defaults, label fallback, and Codable round-trip:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite
struct MacHostTests {
    @Test
    func localHostHasStableIdentity() {
        #expect(MacHost.local.id == MacHost.localID)
        #expect(MacHost.local.label == "This Mac")
        #expect(MacHost.local.kind == .local)
    }

    @Test
    func sshHostDefaultsLabelAndPorts() {
        let host = MacHost.ssh(sshHost: "dev-mini", username: nil)

        #expect(host.label == "dev-mini")
        #expect(host.sshConfig?.sshPort == 22)
        #expect(host.sshConfig?.remoteGrafttyPort == 8799)
    }

    @Test
    func sshHostCodableRoundTrips() throws {
        let host = MacHost.ssh(
            label: "Mini",
            sshHost: "dev-mini",
            username: "btucker",
            sshPort: 2200,
            remoteGrafttyPort: 9000
        )

        let decoded = try JSONDecoder().decode(MacHost.self, from: JSONEncoder().encode(host))

        #expect(decoded == host)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MacHostTests`

Expected: compile failure because `MacHost` does not exist.

- [ ] **Step 3: Implement minimal host model**

Create `Sources/GrafttyKit/Hosts/MacHost.swift`:

```swift
import Foundation

public struct MacHost: Codable, Sendable, Identifiable, Hashable {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let local = MacHost(id: localID, label: "This Mac", kind: .local)

    public let id: UUID
    public var label: String
    public var kind: MacHostKind
    public var addedAt: Date
    public var lastConnectedAt: Date?

    public var sshConfig: SSHMacHostConfig? {
        if case .ssh(let config) = kind { return config }
        return nil
    }

    public init(
        id: UUID = UUID(),
        label: String,
        kind: MacHostKind,
        addedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.addedAt = addedAt
        self.lastConnectedAt = lastConnectedAt
    }

    public static func ssh(
        label: String? = nil,
        sshHost: String,
        username: String?,
        sshPort: Int = 22,
        remoteGrafttyPort: Int = 8799
    ) -> MacHost {
        let resolvedLabel = (label?.isEmpty == false) ? label! : sshHost
        return MacHost(
            label: resolvedLabel,
            kind: .ssh(SSHMacHostConfig(
                sshHost: sshHost,
                sshUsername: username,
                sshPort: sshPort,
                remoteGrafttyPort: remoteGrafttyPort
            ))
        )
    }
}

public enum MacHostKind: Codable, Sendable, Hashable {
    case local
    case ssh(SSHMacHostConfig)
}

public struct SSHMacHostConfig: Codable, Sendable, Hashable {
    public var sshHost: String
    public var sshUsername: String?
    public var sshPort: Int
    public var remoteGrafttyPort: Int

    public init(
        sshHost: String,
        sshUsername: String? = nil,
        sshPort: Int = 22,
        remoteGrafttyPort: Int = 8799
    ) {
        self.sshHost = sshHost
        self.sshUsername = sshUsername
        self.sshPort = sshPort
        self.remoteGrafttyPort = remoteGrafttyPort
    }
}
```

- [ ] **Step 4: Run tests to verify host model passes**

Run: `swift test --filter MacHostTests`

Expected: PASS.

- [ ] **Step 5: Write failing AppState migration tests**

Add tests:

```swift
@Suite
struct MacHostStoreTests {
    @Test
    func freshStateHasImplicitLocalHost() {
        let state = AppState()

        #expect(state.visibleHosts == [MacHost.local])
        #expect(state.hostID(forRepoPath: "/missing") == MacHost.localID)
    }

    @Test
    func legacyJSONDecodesReposAsLocalHost() throws {
        let repoID = UUID()
        let json = """
        {
          "repos": [{
            "id": "\(repoID.uuidString)",
            "path": "/repo",
            "displayName": "repo",
            "isCollapsed": false,
            "worktrees": [],
            "bookmark": null
          }],
          "selectedWorktreePath": null,
          "windowFrame": {"x": 1, "y": 2, "width": 3, "height": 4},
          "sidebarWidth": 240
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(AppState.self, from: json)

        #expect(state.visibleHosts == [MacHost.local])
        #expect(state.hostID(forRepoPath: "/repo") == MacHost.localID)
    }

    @Test
    func addingRemoteHostMakesLocalHostVisible() {
        var state = AppState()
        let remote = MacHost.ssh(sshHost: "dev-mini", username: "btucker")

        state.addHost(remote)

        #expect(state.visibleHosts.map(\.id) == [MacHost.localID, remote.id])
    }
}
```

- [ ] **Step 6: Run tests to verify failure**

Run: `swift test --filter MacHostStoreTests`

Expected: compile failure for missing `visibleHosts`, `addHost`, and `hostID`.

- [ ] **Step 7: Implement AppState host fields and migration**

Modify `AppState`:

```swift
public var hosts: [MacHost]
public var repoHostAssignments: [String: UUID]

public init(
    repos: [RepoEntry] = [],
    selectedWorktreePath: String? = nil,
    windowFrame: WindowFrame = WindowFrame(),
    sidebarWidth: Double = 240,
    hosts: [MacHost] = [],
    repoHostAssignments: [String: UUID] = [:]
) {
    self.repos = repos
    self.selectedWorktreePath = selectedWorktreePath
    self.windowFrame = windowFrame
    self.sidebarWidth = sidebarWidth
    self.hosts = hosts
    self.repoHostAssignments = repoHostAssignments
}

public var visibleHosts: [MacHost] {
    let remoteHosts = hosts.filter { $0.id != MacHost.localID }
    guard !remoteHosts.isEmpty else { return [MacHost.local] }
    return [MacHost.local] + remoteHosts.sorted { $0.label < $1.label }
}

public mutating func addHost(_ host: MacHost) {
    guard host.id != MacHost.localID else { return }
    if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
        hosts[idx] = host
    } else {
        hosts.append(host)
    }
}

public func hostID(forRepoPath path: String) -> UUID {
    repoHostAssignments[path] ?? MacHost.localID
}
```

Add custom `CodingKeys` / `init(from:)` to default missing `hosts` and `repoHostAssignments` for legacy JSON.

Update `addRepo(_:)` to assign local host by default:

```swift
public mutating func addRepo(_ repo: RepoEntry, hostID: UUID = MacHost.localID) {
    guard !repos.contains(where: { $0.path == repo.path && self.hostID(forRepoPath: $0.path) == hostID }) else { return }
    repos.append(repo)
    repoHostAssignments[repo.path] = hostID
}
```

Keep existing call sites compiling by preserving the default argument.

- [ ] **Step 8: Run tests to verify pass**

Run: `swift test --filter MacHost`

Expected: PASS.

- [ ] **Step 9: Run existing AppState tests**

Run: `swift test --filter AppState`

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/GrafttyKit/Hosts/MacHost.swift Sources/GrafttyKit/Model/AppState.swift Tests/GrafttyKitTests/Hosts/MacHostTests.swift Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift
git commit -m "Add Mac host model"
```

---

## Task 2: Add Host-Scoped Sidebar Grouping Without Remote Data Yet

**Files:**
- Create: `Sources/GrafttyKit/Hosts/HostRepositorySnapshot.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift`

- [ ] **Step 1: Write failing pure grouping tests**

Add tests for flat local-only grouping and multi-host grouping:

```swift
@Test
func localOnlySidebarGroupsAreFlat() {
    var state = AppState()
    state.addRepo(RepoEntry(path: "/repo-a", displayName: "repo-a"))

    let groups = HostRepositorySnapshot.groups(for: state)

    #expect(groups.count == 1)
    #expect(groups[0].hostHeader == nil)
    #expect(groups[0].repos.map(\.displayName) == ["repo-a"])
}

@Test
func multipleHostsShowHostHeadersWithoutChangingRepoEntries() {
    var state = AppState()
    let remote = MacHost.ssh(label: "dev-mini", sshHost: "dev-mini", username: nil)
    state.addHost(remote)
    state.addRepo(RepoEntry(path: "/local", displayName: "local"))
    state.addRepo(RepoEntry(path: "/remote", displayName: "remote"), hostID: remote.id)

    let groups = HostRepositorySnapshot.groups(for: state)

    #expect(groups.map(\.hostHeader) == ["This Mac", "dev-mini"])
    #expect(groups[0].repos.map(\.displayName) == ["local"])
    #expect(groups[1].repos.map(\.displayName) == ["remote"])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter multipleHostsShowHostHeaders`

Expected: compile failure because `HostRepositorySnapshot` does not exist.

- [ ] **Step 3: Implement grouping helper**

Create `HostRepositorySnapshot.swift`:

```swift
import Foundation

public struct HostRepositorySnapshot: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var host: MacHost
        public var hostHeader: String?
        public var repos: [RepoEntry]
    }

    public static func groups(for state: AppState) -> [Group] {
        let hasRemoteHosts = state.visibleHosts.contains { $0.id != MacHost.localID }
        return state.visibleHosts.compactMap { host in
            let repos = state.repos.filter { state.hostID(forRepoPath: $0.path) == host.id }
            if repos.isEmpty && host.id == MacHost.localID && hasRemoteHosts { return nil }
            return Group(
                id: host.id,
                host: host,
                hostHeader: hasRemoteHosts ? host.label : nil,
                repos: repos
            )
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter HostRepositorySnapshot`

Expected: PASS.

- [ ] **Step 5: Modify SidebarView to render groups**

Add `let onAddHost: () -> Void`.

Replace the top-level `ForEach(appState.repos)` with:

```swift
ForEach(HostRepositorySnapshot.groups(for: appState)) { group in
    if let header = group.hostHeader {
        Section {
            ForEach(group.repos) { repo in
                repoSection(repo)
            }
        } header: {
            Text(header)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contextMenu {
                    Button("Test Connection") {}
                    Button("Remove Host") {}
                }
        }
    } else {
        ForEach(group.repos) { repo in
            repoSection(repo)
        }
    }
}
```

Keep repo rows at the same list level under section headers. Do not wrap repos in another `DisclosureGroup`.

- [ ] **Step 6: Add Add Host affordance**

Replace the bottom `Button(action: onAddRepo)` with a `Menu`:

```swift
Menu {
    Button("Add Repository", action: onAddRepo)
    Button("Add Host", action: onAddHost)
} label: {
    Label("Add", systemImage: "plus")
        .frame(maxWidth: .infinity)
        .foregroundColor(theme.foreground.opacity(0.8))
}
.menuStyle(.button)
.buttonStyle(.plain)
.padding(8)
```

Wire `onAddHost` from `MainWindow` to a temporary no-op state function:

```swift
@State private var showingAddHost = false

private func addHost() {
    showingAddHost = true
}
```

- [ ] **Step 7: Build**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Hosts/HostRepositorySnapshot.swift Sources/Graftty/Views/SidebarView.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift
git commit -m "Group sidebar repositories by host"
```

---

## Task 3: Implement System SSH Local Forward Service

**Files:**
- Create: `Sources/GrafttyKit/Hosts/SSHLocalForward.swift`
- Test: `Tests/GrafttyKitTests/Hosts/SSHLocalForwardTests.swift`

- [ ] **Step 1: Write failing command-construction tests**

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite
struct SSHLocalForwardTests {
    @Test
    func buildsSSHArgumentsUsingConfigAlias() throws {
        let config = SSHMacHostConfig(sshHost: "dev-mini", sshUsername: nil, sshPort: 22, remoteGrafttyPort: 8799)

        let args = SSHLocalForwardCommand.arguments(
            config: config,
            localPort: 49152
        )

        #expect(args.contains("-N"))
        #expect(args.contains("-L"))
        #expect(args.contains("127.0.0.1:49152:127.0.0.1:8799"))
        #expect(args.last == "dev-mini")
    }

    @Test
    func buildsSSHArgumentsWithUserAndNonDefaultPort() {
        let config = SSHMacHostConfig(sshHost: "192.168.1.42", sshUsername: "btucker", sshPort: 2200)

        let args = SSHLocalForwardCommand.arguments(config: config, localPort: 49152)

        #expect(args.contains("-p"))
        #expect(args.contains("2200"))
        #expect(args.last == "btucker@192.168.1.42")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SSHLocalForwardTests`

Expected: compile failure because `SSHLocalForwardCommand` does not exist.

- [ ] **Step 3: Implement command builder and process protocol**

Create:

```swift
import Foundation

public enum SSHLocalForwardError: Error, Equatable {
    case sshExited(Int32)
    case localPortUnavailable
}

public struct SSHLocalForwardCommand: Sendable, Equatable {
    public static func arguments(config: SSHMacHostConfig, localPort: Int) -> [String] {
        var args = [
            "-N",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(config.remoteGrafttyPort)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30"
        ]
        if config.sshPort != 22 {
            args += ["-p", "\(config.sshPort)"]
        }
        let destination = config.sshUsername.map { "\($0)@\(config.sshHost)" } ?? config.sshHost
        args.append(destination)
        return args
    }
}

public protocol SSHLocalForwardProcess: Sendable {
    var localPort: Int { get }
    func stop()
}

public protocol SSHLocalForwarding: Sendable {
    func start(config: SSHMacHostConfig) async throws -> any SSHLocalForwardProcess
}
```

- [ ] **Step 4: Run tests to verify command builder passes**

Run: `swift test --filter SSHLocalForwardTests`

Expected: PASS.

- [ ] **Step 5: Add local port allocator tests**

Write a test for reserving an ephemeral local port:

```swift
@Test
func localPortAllocatorReturnsBindablePort() throws {
    let port = try LocalPortAllocator.ephemeralLoopbackPort()
    #expect(port > 0)
}
```

- [ ] **Step 6: Implement `LocalPortAllocator`**

Implement with BSD sockets or `NWListener` if already available. Keep it synchronous and testable. The function should bind `127.0.0.1:0`, read the assigned port, close the socket, and return the port. Document the small race before `ssh` binds; `ExitOnForwardFailure=yes` catches it.

- [ ] **Step 7: Implement real process wrapper**

Add:

```swift
public final class SystemSSHLocalForwarder: SSHLocalForwarding, @unchecked Sendable {
    public init() {}

    public func start(config: SSHMacHostConfig) async throws -> any SSHLocalForwardProcess {
        let port = try LocalPortAllocator.ephemeralLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHLocalForwardCommand.arguments(config: config, localPort: port)
        try process.run()
        try await Task.sleep(nanoseconds: 250_000_000)
        if !process.isRunning {
            throw SSHLocalForwardError.sshExited(process.terminationStatus)
        }
        return RunningSystemSSHLocalForward(process: process, localPort: port)
    }
}
```

Use a short startup wait only to catch immediate `ExitOnForwardFailure` failures. The real Graftty probe in Task 4 determines whether the tunnel is useful.

- [ ] **Step 8: Run tests**

Run: `swift test --filter SSHLocalForwardTests`

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Hosts/SSHLocalForward.swift Tests/GrafttyKitTests/Hosts/SSHLocalForwardTests.swift
git commit -m "Add SSH local forwarding service"
```

---

## Task 4: Add Remote Graftty Probe And Layered Errors

**Files:**
- Create: `Sources/GrafttyKit/Hosts/RemoteGrafttyClient.swift`
- Test: `Tests/GrafttyKitTests/Hosts/RemoteGrafttyClientTests.swift`

- [ ] **Step 1: Write failing probe tests**

Use `URLProtocol` injection or a small local `URLSessionConfiguration.ephemeral` with a custom protocol. Test that HTTP 200 is accepted and transport/HTTP failures map to clear errors.

```swift
@Suite
struct RemoteGrafttyClientTests {
    @Test
    func probeAcceptsSuccessfulResponse() async throws {
        let client = RemoteGrafttyClient(session: .mock(statusCode: 200, body: Data()))
        try await client.probe(baseURL: URL(string: "http://127.0.0.1:49152/")!)
    }

    @Test
    func probeRejectsHTTPFailure() async {
        let client = RemoteGrafttyClient(session: .mock(statusCode: 404, body: Data()))
        await #expect(throws: RemoteGrafttyClient.Error.grafttyUnavailable) {
            try await client.probe(baseURL: URL(string: "http://127.0.0.1:49152/")!)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter RemoteGrafttyClientTests`

Expected: compile failure.

- [ ] **Step 3: Implement probe client**

Create:

```swift
import Foundation

public struct RemoteGrafttyClient: Sendable {
    public enum Error: Swift.Error, Equatable {
        case grafttyUnavailable
        case transport
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func probe(baseURL: URL) async throws {
        do {
            let (_, response) = try await session.data(from: baseURL.appending(path: "repos"))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw Error.grafttyUnavailable
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport
        }
    }
}
```

If `/repos` requires an exact existing helper, reuse the current `ReposFetcher` endpoint path rather than inventing a new health endpoint.

- [ ] **Step 4: Add layered test-connection coordinator tests**

Create a pure coordinator in the same file:

```swift
public enum AddHostConnectionResult: Equatable {
    case success(localBaseURL: URL)
    case sshFailed(String)
    case grafttyUnavailable(String)
}
```

Test:

```swift
@Test
func testConnectionReportsGrafttyUnavailableWhenTunnelStartsButProbeFails() async {
    let tester = AddHostConnectionTester(
        forwarder: FakeForwarder(localPort: 49152),
        client: FakeRemoteClient(result: .failure(.grafttyUnavailable))
    )

    let result = await tester.test(config)

    #expect(result == .grafttyUnavailable("SSH connected, but Graftty did not respond on the remote Mac. Open Graftty on dev-mini and enable SSH Tunnel mode."))
}
```

- [ ] **Step 5: Implement coordinator**

Implement `AddHostConnectionTester` with injected `SSHLocalForwarding` and probe client protocol. It should stop the tunnel on failed probe.

- [ ] **Step 6: Run tests**

Run: `swift test --filter RemoteGrafttyClientTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Hosts/RemoteGrafttyClient.swift Tests/GrafttyKitTests/Hosts/RemoteGrafttyClientTests.swift
git commit -m "Add remote Graftty connection probe"
```

---

## Task 5: Add Add Host Sheet UI

**Files:**
- Create: `Sources/Graftty/Views/AddHostSheet.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostTests.swift`

- [ ] **Step 1: Write failing validation tests**

Add pure validation to `MacHost` or a new `AddHostFormModel` in GrafttyKit:

```swift
@Test
func addHostFormRejectsEmptyHost() {
    var form = AddHostFormModel()
    form.host = " "

    #expect(form.validatedHost() == nil)
}

@Test
func addHostFormDefaultsLabelAndUsername() {
    var form = AddHostFormModel()
    form.host = "dev-mini"
    form.username = ""

    let host = form.makeHost(currentUsername: "btucker")

    #expect(host?.label == "dev-mini")
    #expect(host?.sshConfig?.sshUsername == nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter addHostForm`

Expected: compile failure.

- [ ] **Step 3: Implement pure form model**

Create `AddHostFormModel` in `MacHost.swift` or a new focused file if it grows:

```swift
public struct AddHostFormModel: Sendable, Equatable {
    public var label = ""
    public var host = ""
    public var username = ""
    public var sshPort = 22
    public var remoteGrafttyPort = 8799

    public func makeHost() -> MacHost? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        return MacHost.ssh(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            sshHost: trimmedHost,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sshPort: sshPort,
            remoteGrafttyPort: remoteGrafttyPort
        )
    }
}
```

- [ ] **Step 4: Run validation tests**

Run: `swift test --filter addHostForm`

Expected: PASS.

- [ ] **Step 5: Build AddHostSheet**

Create a compact SwiftUI sheet:

- TextField: Display Name
- TextField: Hostname, IP, or SSH alias
- TextField: Username
- Stepper/TextField: SSH Port
- Stepper/TextField: Graftty Port
- Static prerequisite copy
- `Test Connection` button
- `Save` button disabled until host is non-empty and ports are valid

Expose:

```swift
struct AddHostSheet: View {
    let tester: AddHostConnectionTester
    let onSave: (MacHost) -> Void
}
```

Use `@State private var form = AddHostFormModel()`.

- [ ] **Step 6: Wire MainWindow sheet**

In `MainWindow`:

```swift
@State private var showingAddHost = false

.sheet(isPresented: $showingAddHost) {
    AddHostSheet(tester: AddHostConnectionTester()) { host in
        appState.addHost(host)
        showingAddHost = false
    }
}
```

- [ ] **Step 7: Build**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Graftty/Views/AddHostSheet.swift Sources/Graftty/Views/MainWindow.swift Sources/GrafttyKit/Hosts/MacHost.swift Tests/GrafttyKitTests/Hosts/MacHostTests.swift
git commit -m "Add remote host sheet"
```

---

## Task 6: Fetch And Cache Remote Repositories

**Files:**
- Modify: `Sources/GrafttyKit/Hosts/RemoteGrafttyClient.swift`
- Modify: `Sources/GrafttyKit/Model/AppState.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyKitTests/Hosts/RemoteGrafttyClientTests.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift`

- [ ] **Step 1: Write failing remote repo decode test**

Use the same JSON shape currently returned by `/worktrees/panes` or the existing web/mobile endpoint. If the endpoint already returns `[WorktreePanes]`, map it to sidebar snapshots without local git metadata.

Test:

```swift
@Test
func fetchRemoteWorktreesMapsToRepoEntries() async throws {
    let json = """
    [{
      "path": "/Users/me/repo-a",
      "branch": "main",
      "layout": null
    }]
    """.data(using: .utf8)!
    let client = RemoteGrafttyClient(session: .mock(statusCode: 200, body: json))

    let repos = try await client.fetchRepositorySnapshot(baseURL: URL(string: "http://127.0.0.1:49152/")!)

    #expect(repos.first?.displayName == "repo-a")
}
```

Adjust the fixture to the real `WorktreePanes` schema after inspecting `Sources/GrafttyProtocol/WorktreePanes.swift`.

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter fetchRemoteWorktreesMapsToRepoEntries`

Expected: compile failure or decode failure.

- [ ] **Step 3: Implement remote snapshot fetch**

Add `fetchRepositorySnapshot(baseURL:) async throws -> [RepoEntry]` to `RemoteGrafttyClient`. Group remote worktrees by repo display name/path using the same display rules mobile uses. Mark remote entries as not locally watchable by not installing watchers for them.

- [ ] **Step 4: Add AppState remote cache**

Add:

```swift
public var remoteRepoCache: [UUID: [RepoEntry]]
```

Default to `[:]` in Codable migration. Update `HostRepositorySnapshot.groups(for:)` to use:

- local host: `state.repos` assigned to local
- remote hosts: `state.remoteRepoCache[host.id] ?? []`

Do not persist remote caches in V1 if this gets too invasive. If not persisted, keep it outside `AppState` in `MainWindow @State`. Pick one approach and update tests to match. Preferred: persist cache only if the implementation is small; otherwise app-session cache is acceptable for V1.

- [ ] **Step 5: Wire refresh on host save/select**

After Add Host succeeds:

1. Add host to `appState`.
2. Start tunnel.
3. Fetch snapshot.
4. Store snapshot for that host.
5. Stop tunnel or keep it in active tunnel pool if user is about to interact.

Add a `refreshHost(_:)` function in `MainWindow`.

- [ ] **Step 6: Run tests**

Run: `swift test --filter RemoteGrafttyClientTests`

Expected: PASS.

- [ ] **Step 7: Build**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Hosts/RemoteGrafttyClient.swift Sources/GrafttyKit/Model/AppState.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyKitTests/Hosts/RemoteGrafttyClientTests.swift Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift
git commit -m "Fetch remote host repositories"
```

---

## Task 7: Route Remote Worktree Selection Through Tunnel URLs

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift` only if terminal attachment needs a URL-aware path.
- Test: add focused pure tests if a route resolver is extracted.

- [ ] **Step 1: Extract route resolver test**

Create a pure resolver that maps a worktree path to either local handling or remote host handling:

```swift
@Test
func resolverIdentifiesRemoteWorktreeHost() {
    let remoteID = UUID()
    var state = AppState()
    state.remoteRepoCache[remoteID] = [RepoEntry(path: "/remote/repo", displayName: "repo")]

    let route = WorktreeRoute.resolve(path: "/remote/repo", state: state)

    #expect(route == .remote(hostID: remoteID, worktreePath: "/remote/repo"))
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter WorktreeRoute`

Expected: compile failure.

- [ ] **Step 3: Implement route resolver**

Create a small type in `GrafttyKit/Hosts`:

```swift
public enum WorktreeRoute: Equatable {
    case local(worktreePath: String)
    case remote(hostID: UUID, worktreePath: String)
}
```

Remote selection should not call local filesystem `selectWorktree` directly.

- [ ] **Step 4: Decide V1 remote terminal behavior**

If existing Mac terminal rendering is tightly coupled to local zmx/pty state, make V1 remote selection open the existing web/mobile terminal UI in a web view or external browser through the tunnel. Do not fake local terminal state with remote paths.

Recommended V1:

- Sidebar can list remote repos/worktrees.
- Clicking a remote worktree starts/reuses tunnel and opens the remote web UI URL for that worktree/session when available.
- If per-pane native Mac terminal attachment needs deeper work, gate it behind a follow-up plan.

This is the main risk area. Do not let the implementation accidentally run local `git`, local zmx, or local watchers on a remote path.

- [ ] **Step 5: Wire remote selection safely**

In `SidebarView`, pass host context in selection callbacks:

```swift
let onSelect: (UUID, String) -> Void
```

For local host, call existing `selectWorktree`. For remote host, call `selectRemoteWorktree(hostID:path:)`.

- [ ] **Step 6: Build**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Hosts Sources/Graftty/Views/SidebarView.swift Sources/Graftty/Views/MainWindow.swift
git commit -m "Route remote worktree selection"
```

---

## Task 8: Host Context Menus And Lifecycle Cleanup

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift`

- [ ] **Step 1: Write failing remove-host state test**

```swift
@Test
func removingHostDropsRemoteCacheAndAssignments() {
    var state = AppState()
    let remote = MacHost.ssh(sshHost: "dev-mini", username: nil)
    state.addHost(remote)
    state.remoteRepoCache[remote.id] = [RepoEntry(path: "/remote", displayName: "remote")]

    state.removeHost(remote.id)

    #expect(!state.visibleHosts.contains(where: { $0.id == remote.id }))
    #expect(state.remoteRepoCache[remote.id] == nil)
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter removingHostDropsRemoteCache`

Expected: missing `removeHost`.

- [ ] **Step 3: Implement remove/update host state**

Add:

```swift
public mutating func removeHost(_ hostID: UUID) {
    guard hostID != MacHost.localID else { return }
    hosts.removeAll { $0.id == hostID }
    remoteRepoCache[hostID] = nil
    repoHostAssignments = repoHostAssignments.filter { $0.value != hostID }
}
```

- [ ] **Step 4: Add host header context menu actions**

In `SidebarView`, make host header context menus call closures:

```swift
let onTestHost: (MacHost) -> Void
let onDisconnectHost: (MacHost) -> Void
let onRemoveHost: (MacHost) -> Void
let onCopySSHCommand: (MacHost) -> Void
```

Keep menu only for remote hosts where actions apply.

- [ ] **Step 5: Implement MainWindow actions**

- `testHost(_:)`: runs `AddHostConnectionTester`, alerts result.
- `disconnectHost(_:)`: stops active tunnel for host.
- `removeHost(_:)`: confirms, stops tunnel, removes host.
- `copySSHCommand(_:)`: copies equivalent command to pasteboard.

- [ ] **Step 6: Stop tunnels on app quit/background lifecycle**

In `GrafttyApp` or `MainWindow`, maintain an active tunnel pool:

```swift
@State private var activeRemoteTunnels: [UUID: any SSHLocalForwardProcess] = [:]
```

Stop all on app termination/scene close. If there is already an app lifecycle hook, use it; otherwise stop on `MainWindow.onDisappear`.

- [ ] **Step 7: Run tests and build**

Run:

```bash
swift test --filter MacHostStoreTests
swift build --build-tests -Xswiftc -warnings-as-errors
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Model/AppState.swift Sources/Graftty/Views/SidebarView.swift Sources/Graftty/Views/MainWindow.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/Hosts/MacHostStoreTests.swift
git commit -m "Add remote host actions"
```

---

## Task 9: Update Web Settings Copy And Documentation

**Files:**
- Modify: `Sources/Graftty/Web/WebSettingsPane.swift`
- Modify: `docs/superpowers/specs/2026-04-24-ssh-tunnel-access-design.md` if needed.
- Test: existing UI text tests if present; otherwise build-only.

- [ ] **Step 1: Update SSH tunnel mode copy**

Change Mac-to-Mac copy from only manual browser instructions to mention:

```text
From another Mac, add this Mac as an SSH Host in Graftty, or run a manual tunnel:
ssh -L <local-port>:127.0.0.1:<port> user@this-mac
```

Keep mobile public-key instructions separate so Mac-to-Mac users do not think Graftty generates Mac keys.

- [ ] **Step 2: Build**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Web/WebSettingsPane.swift docs/superpowers/specs/2026-04-24-ssh-tunnel-access-design.md
git commit -m "docs: update SSH host guidance"
```

---

## Task 10: Final Verification

**Files:** all touched files.

- [ ] **Step 1: Run diff hygiene**

Run: `git diff --check`

Expected: no output.

- [ ] **Step 2: Run macOS package build with warnings as errors**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`

Expected: PASS.

- [ ] **Step 3: Run macOS package test binary**

Run: `xcrun xctest .build/debug/GrafttyPackageTests.xctest`

Expected: PASS.

- [ ] **Step 4: Run iOS mobile kit build**

Run: `xcodebuild build -scheme GrafttyMobileKit -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: PASS.

- [ ] **Step 5: Manual smoke test local-only sidebar**

Launch Graftty with a state containing only local repos.

Expected:

- no `This Mac` header;
- repos remain top-level;
- Add Repository still works;
- existing worktree selection still works.

- [ ] **Step 6: Manual smoke test remote host failure layering**

Add a host where SSH works but remote Graftty is not running in SSH tunnel mode.

Expected:

- SSH step succeeds;
- final error says Graftty did not respond and instructs user to open Graftty on the remote Mac and enable SSH Tunnel mode.

- [ ] **Step 7: Manual smoke test remote host success**

On a second Mac, run Graftty in SSH tunnel mode. Add that host locally.

Expected:

- Test Connection succeeds;
- sidebar shows host sections;
- local repos stay under `This Mac`;
- remote repos appear under remote host without additional indentation;
- disconnect/remove host does not modify the remote Mac.

- [ ] **Step 8: Push and watch CI**

```bash
git push origin tailscale-alternative
gh pr checks 87 --watch --interval 10
```

Expected: all checks pass.

---

## Risks To Watch

- **Remote terminal scope:** The existing Mac terminal UI is deeply tied to local zmx processes and local `AppState` paths. Do not accidentally run local operations against remote paths. If native remote pane attachment is larger than expected, stop at remote host/repo listing plus safe remote web UI handoff and write a follow-up plan.
- **System ssh lifecycle:** `Process` can tell us when ssh exits, but not why without stderr capture. Capture stderr for user-visible SSH failures.
- **SSH config compatibility:** Prefer `/usr/bin/ssh` over a native library for Mac-to-Mac V1 so aliases, agent, `ProxyJump`, and other user-managed config work naturally.
- **State migration:** Existing users must decode old `state.json` without hosts and see the same local-only sidebar.
- **Sidebar indentation:** Use `Section` headers, not nested host rows, to preserve repo alignment.

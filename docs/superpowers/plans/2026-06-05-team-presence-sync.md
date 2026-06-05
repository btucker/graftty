# Team Presence Sync (P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teammates' worktrees appear in the graftty sidebar alongside your own, synced via git refs on the repo's shared remote — zero new infrastructure.

**Architecture:** Each graftty publishes a small JSON "presence document" describing its worktrees to `refs/graftty/presence/<slug>` on `origin` (the JSON rides in the commit message of an empty-tree commit — no stdin needed for git plumbing). A polling service fetches teammates' refs, decodes their documents, and feeds an observable store the sidebar renders as ambient, read-only rows. Sharing is opt-in per repo via the repo context menu; disabling deletes your remote ref.

**Tech Stack:** Swift 5.x, Swift Testing (`@Test` titles carry `@spec` EARS text), existing `GitRunner`/`CLIExecutor` for git, existing `PollingTicker` pattern for polling, SwiftUI sidebar.

**Spec prefix:** `SYNC-*` (verified unused in SPECS.md).

**Design doc:** `docs/superpowers/specs/2026-06-05-team-worktree-sharing-design.md` (Phase 1).

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/GrafttyKit/Presence/PresenceDocument.swift` | Wire format: one user's published worktree list; deterministic JSON; `build(from:)` filter rules |
| Create `Sources/GrafttyKit/Presence/PresenceIdentity.swift` | Slug derivation from git `user.email`; identity probe |
| Create `Sources/GrafttyKit/Presence/PresenceRefSync.swift` | Git plumbing: publish/fetch/delete presence refs |
| Create `Sources/GrafttyKit/Presence/TeamPresenceSync.swift` | Polling service + `TeamPresenceSyncStore` (ObservableObject) + `RemoteWorktreePresence` |
| Modify `Sources/GrafttyKit/Model/RepoEntry.swift` | Add `presenceSharingEnabled: Bool` (default false, backwards-compatible decode) |
| Create `Sources/Graftty/Views/RemoteWorktreeRow.swift` | Ambient sidebar row for a teammate's worktree |
| Modify `Sources/Graftty/Views/SidebarView.swift` | Render remote rows in repo section; repo context-menu toggle |
| Modify `Sources/Graftty/GrafttyApp.swift` | Service construction + ticker wiring + toggle handler |
| Create `Tests/GrafttyKitTests/Presence/*.swift` | All spec tests (this target can use `Tests/GrafttyKitTests/Git/GitIntegrationHelpers.swift`) |
| Create `Tests/GrafttyTests/Specs/SyncTodo.swift` | Inventory entry for the UI-render spec (SYNC-5.1) |

Conventions every task must follow (from CLAUDE.md):
- TDD: write the failing `@Test` first, see it fail, implement, see it pass.
- Every task's commit step: run `scripts/generate-specs.py` and include the regenerated `SPECS.md` in the commit. Commit messages cite spec IDs, e.g. `feat(SYNC-1.1): …`.
- Run tests with `swift test --filter <TestTypeName>` for speed; full `swift test` in the final task.

---

### Task 1: PresenceDocument model

**Files:**
- Create: `Sources/GrafttyKit/Presence/PresenceDocument.swift`
- Test: `Tests/GrafttyKitTests/Presence/PresenceDocumentTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceDocument — encoding and building")
struct PresenceDocumentTests {
    @Test("@spec SYNC-1.2: Presence documents shall round-trip through JSON with ISO-8601 timestamps and stable key ordering.")
    func jsonRoundTrip() throws {
        let doc = PresenceDocument(
            version: 1,
            user: "Sarah",
            email: "sarah@example.com",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            worktrees: [
                .init(name: "auth-refactor", branch: "auth-refactor", state: "running"),
                .init(name: "fix-pairing", branch: "fix/pairing", state: "idle"),
            ]
        )
        let data = try PresenceDocument.encode(doc)
        let decoded = try PresenceDocument.decode(data)
        #expect(decoded == doc)
        // Deterministic output (sorted keys) so unchanged docs compare equal as bytes.
        #expect(try PresenceDocument.encode(doc) == data)
        // ISO-8601 wire format, not epoch seconds.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2026-05-29T") || json.contains("Z\""))
    }

    @Test("@spec SYNC-1.1: When building a presence document from a repo's worktrees, the application shall include only worktrees with an on-disk checkout, mapping running to \"running\" and closed to \"idle\".")
    func buildFiltersAndMapsStates() throws {
        var running = WorktreeEntry(path: "/tmp/wt/auth-refactor", branch: "auth-refactor")
        running.state = .running
        var closed = WorktreeEntry(path: "/tmp/wt/fix-pairing", branch: "fix/pairing")
        closed.state = .closed
        var stale = WorktreeEntry(path: "/tmp/wt/old", branch: "old")
        stale.state = .stale
        var creating = WorktreeEntry(path: "/tmp/wt/new", branch: "new")
        creating.state = .creating

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let doc = PresenceDocument.build(
            user: "Sarah",
            email: "sarah@example.com",
            worktrees: [running, closed, stale, creating],
            now: now
        )
        #expect(doc.updatedAt == now)
        #expect(doc.worktrees == [
            .init(name: "auth-refactor", branch: "auth-refactor", state: "running"),
            .init(name: "fix-pairing", branch: "fix/pairing", state: "idle"),
        ])
    }

    @Test("Malformed JSON fails to decode rather than producing a partial document.")
    func malformedJSONThrows() {
        let junk = Data("not json".utf8)
        #expect(throws: (any Error).self) { try PresenceDocument.decode(junk) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PresenceDocumentTests`
Expected: FAIL — `PresenceDocument` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// @spec SYNC-1.2
/// One user's published presence: the worktrees they currently have checked
/// out for a repo, as deterministic JSON (sorted keys, ISO-8601 dates).
/// Published to `refs/graftty/presence/<slug>` on the repo's origin remote;
/// the JSON travels in the commit message of an empty-tree commit.
public struct PresenceDocument: Codable, Sendable, Equatable {
    public struct Worktree: Codable, Sendable, Equatable {
        public let name: String
        public let branch: String
        /// "running" | "idle"
        public let state: String

        public init(name: String, branch: String, state: String) {
            self.name = name
            self.branch = branch
            self.state = state
        }
    }

    public let version: Int
    public let user: String
    public let email: String
    public let updatedAt: Date
    public let worktrees: [Worktree]

    public init(version: Int, user: String, email: String, updatedAt: Date, worktrees: [Worktree]) {
        self.version = version
        self.user = user
        self.email = email
        self.updatedAt = updatedAt
        self.worktrees = worktrees
    }

    /// Builds the document to publish from a repo's current worktrees.
    /// Stale and in-flight (creating/deleting) entries are excluded: stale
    /// worktrees have no on-disk checkout and in-flight ones are transient.
    public static func build(
        user: String,
        email: String,
        worktrees: [WorktreeEntry],
        now: Date
    ) -> PresenceDocument {
        let published = worktrees.compactMap { entry -> Worktree? in
            let state: String
            switch entry.state {
            case .running: state = "running"
            case .closed: state = "idle"
            case .stale, .creating, .deleting: return nil
            }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            return Worktree(name: name, branch: entry.branch, state: state)
        }
        return PresenceDocument(
            version: 1, user: user, email: email, updatedAt: now, worktrees: published
        )
    }

    public static func encode(_ doc: PresenceDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    public static func decode(_ data: Data) throws -> PresenceDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PresenceDocument.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PresenceDocumentTests`
Expected: 3 PASS.

- [ ] **Step 5: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Presence/PresenceDocument.swift Tests/GrafttyKitTests/Presence/PresenceDocumentTests.swift SPECS.md
git commit -m "feat(SYNC-1.1, SYNC-1.2): presence document model with deterministic JSON"
```

---

### Task 2: PresenceIdentity — slug + git identity probe

**Files:**
- Create: `Sources/GrafttyKit/Presence/PresenceIdentity.swift`
- Test: `Tests/GrafttyKitTests/Presence/PresenceIdentityTests.swift`

- [ ] **Step 1: Write the failing tests**

Note: the git-probe test uses the temp-repo helpers from `Tests/GrafttyKitTests/Git/GitIntegrationHelpers.swift` (`makeTempDir`, `shellInRepo`) — same target, no import needed.

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceIdentity — slug and probe")
struct PresenceIdentityTests {
    @Test("@spec SYNC-1.3: The application shall derive the presence slug from the git user.email by lowercasing and replacing each run of non-alphanumeric characters with a single hyphen.")
    func slugDerivation() {
        #expect(PresenceIdentity.slug(forEmail: "ben@btucker.net") == "ben-btucker-net")
        #expect(PresenceIdentity.slug(forEmail: "Sarah.O'Neil+work@Example.COM") == "sarah-o-neil-work-example-com")
        #expect(PresenceIdentity.slug(forEmail: "--weird--@x.io") == "weird-x-io")
    }

    @Test("load reads user.name and user.email from the repo's git config.")
    func loadProbesGitConfig() async throws {
        let dir = try makeTempDir(prefix: "graftty-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        try shellInRepo("git init -b main && git config user.name 'Sarah' && git config user.email 'sarah@example.com'", at: dir)

        let identity = try await PresenceIdentity.load(repoPath: dir.path)
        #expect(identity.name == "Sarah")
        #expect(identity.email == "sarah@example.com")
        #expect(identity.slug == "sarah-example-com")
    }

    @Test("load throws when user.email is not configured.")
    func loadThrowsWithoutEmail() async throws {
        let dir = try makeTempDir(prefix: "graftty-identity-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        // GIT_CONFIG_* env vars in shellInRepo's fixed environment don't leak
        // user identity, but the developer's global gitconfig might — so probe
        // with --local scope in the implementation.
        try shellInRepo("git init -b main", at: dir)

        await #expect(throws: (any Error).self) {
            _ = try await PresenceIdentity.load(repoPath: dir.path, scope: .local)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PresenceIdentityTests`
Expected: FAIL — `PresenceIdentity` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Identity used for presence publication, derived from the repo's git config.
public struct PresenceIdentity: Sendable, Equatable {
    public let name: String
    public let email: String

    public var slug: String { Self.slug(forEmail: email) }

    public enum ConfigScope: Sendable {
        case any
        case local

        var extraArgs: [String] {
            switch self {
            case .any: return []
            case .local: return ["--local"]
            }
        }
    }

    public enum IdentityError: Error, Equatable {
        case missingEmail
    }

    /// @spec SYNC-1.3
    /// Slug = lowercased email with each run of non-alphanumeric characters
    /// collapsed to a single hyphen, trimmed of leading/trailing hyphens.
    public static func slug(forEmail email: String) -> String {
        let lowered = email.lowercased()
        var out = ""
        var pendingHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// Probes `git config user.name` / `user.email` at the repo. Email is
    /// required (it keys the presence ref); name falls back to the email's
    /// local part.
    public static func load(repoPath: String, scope: ConfigScope = .any) async throws -> PresenceIdentity {
        @Sendable func probe(_ key: String) async -> String? {
            guard let out = try? await GitRunner.captureAll(
                args: ["config"] + scope.extraArgs + [key], at: repoPath
            ), out.exitCode == 0 else { return nil }
            let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let email = await probe("user.email") else {
            throw IdentityError.missingEmail
        }
        let name = await probe("user.name") ?? String(email.prefix(while: { $0 != "@" }))
        return PresenceIdentity(name: name, email: email)
    }
}
```

Note for the implementer: check `GitRunner.captureAll`'s exact signature in `Sources/GrafttyKit/Git/GitRunner.swift` before writing — it returns `CLIOutput` (stdout/stderr/exitCode). Adjust the call if the label differs.

`String.unicodeScalars.append` requires `out.unicodeScalars` to be mutable through `var out` — if the compiler rejects it, use `out.append(Character(scalar))`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PresenceIdentityTests`
Expected: 3 PASS. (If `loadThrowsWithoutEmail` passes trivially because your global gitconfig leaks in, the `--local` scope is doing its job; verify `loadProbesGitConfig` still passes with `.any` default.)

- [ ] **Step 5: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Presence/PresenceIdentity.swift Tests/GrafttyKitTests/Presence/PresenceIdentityTests.swift SPECS.md
git commit -m "feat(SYNC-1.3): presence identity slug from git user.email"
```

---

### Task 3: PresenceRefSync — git ref publish / fetch / delete

**Files:**
- Create: `Sources/GrafttyKit/Presence/PresenceRefSync.swift`
- Test: `Tests/GrafttyKitTests/Presence/PresenceRefSyncTests.swift`

The mechanism (chosen because `CLIExecutor` has no stdin support, ruling out `git mktree`):
1. **Publish:** write the empty tree (`git hash-object -w -t tree /dev/null`), create a commit on it whose **message is the presence JSON** (`git commit-tree <tree> -m <json>` with `-c` identity overrides so it works without user config), force-push it to `refs/graftty/presence/<slug>` (force because each update replaces — there's no parent chain).
2. **Fetch:** mirror `+refs/graftty/presence/*:refs/graftty/presence/*` with `--prune`, list with `for-each-ref`, read each message with `git show -s --format=%B <ref>`, decode; skip undecodable docs.
3. **Delete:** push an empty refspec `:refs/graftty/presence/<slug>`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PresenceRefSync — git ref round-trip", .serialized)
struct PresenceRefSyncTests {
    private func makeDoc(email: String) -> PresenceDocument {
        PresenceDocument(
            version: 1,
            user: "Sarah",
            email: email,
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            worktrees: [.init(name: "auth-refactor", branch: "auth-refactor", state: "running")]
        )
    }

    @Test("@spec SYNC-2.1: When publishing presence, the application shall push an empty-tree commit carrying the presence JSON in its message to refs/graftty/presence/<slug> on origin, replacing any previous value.")
    func publishCreatesAndReplacesRef() async throws {
        let (root, clone, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = makeDoc(email: "sarah@example.com")
        try await PresenceRefSync.publish(doc, slug: "sarah-example-com", repoPath: clone.path)

        // Ref exists on the upstream (shared remote).
        let lsRemote = try await GitRunner.run(
            args: ["ls-remote", "origin", "refs/graftty/presence/*"], at: clone.path
        )
        #expect(lsRemote.contains("refs/graftty/presence/sarah-example-com"))

        // Publishing again replaces (no non-fast-forward failure).
        let doc2 = PresenceDocument(
            version: 1, user: "Sarah", email: "sarah@example.com",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_100),
            worktrees: []
        )
        try await PresenceRefSync.publish(doc2, slug: "sarah-example-com", repoPath: clone.path)
        _ = upstream  // silence unused warning if not otherwise needed
    }

    @Test("@spec SYNC-2.2: When fetching presence, the application shall mirror refs/graftty/presence/* from origin and decode each document, skipping undecodable refs.")
    func fetchDecodesAllPeerDocs() async throws {
        let (root, cloneA, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        // Second teammate clone.
        let cloneB = root.appendingPathComponent("cloneB")
        try shellInRepo("git clone \(upstream.path) \(cloneB.path)", at: root)

        // B publishes; A fetches.
        let doc = makeDoc(email: "sarah@example.com")
        try await PresenceRefSync.publish(doc, slug: "sarah-example-com", repoPath: cloneB.path)

        let fetched = try await PresenceRefSync.fetchAll(repoPath: cloneA.path)
        #expect(fetched == [doc])
    }

    @Test("@spec SYNC-2.3: When presence sharing is disabled for a repo, the application shall delete the user's presence ref from origin.")
    func deleteRemovesRef() async throws {
        let (root, clone, _) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try await PresenceRefSync.publish(makeDoc(email: "sarah@example.com"), slug: "sarah-example-com", repoPath: clone.path)
        try await PresenceRefSync.delete(slug: "sarah-example-com", repoPath: clone.path)

        let lsRemote = try await GitRunner.run(
            args: ["ls-remote", "origin", "refs/graftty/presence/*"], at: clone.path
        )
        #expect(!lsRemote.contains("sarah-example-com"))
        // Fetching after delete prunes the local mirror too.
        let fetched = try await PresenceRefSync.fetchAll(repoPath: clone.path)
        #expect(fetched.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PresenceRefSyncTests`
Expected: FAIL — `PresenceRefSync` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Publishes and fetches presence documents via git refs on the repo's
/// `origin` remote (`refs/graftty/presence/<slug>`). The JSON document rides
/// in the commit message of an empty-tree commit: no working-tree writes, no
/// stdin-dependent plumbing, and `git show -s --format=%B` reads it back.
public enum PresenceRefSync {
    static func refName(slug: String) -> String { "refs/graftty/presence/\(slug)" }

    /// @spec SYNC-2.1 (behavioral spec on PresenceRefSyncTests)
    public static func publish(_ doc: PresenceDocument, slug: String, repoPath: String) async throws {
        let json = String(decoding: try PresenceDocument.encode(doc), as: UTF8.self)
        // The empty tree is a fixed, well-known object; -w ensures it exists
        // in this repo's object store.
        let tree = try await GitRunner.run(
            args: ["hash-object", "-w", "-t", "tree", "/dev/null"], at: repoPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Synthetic committer identity: presence commits must not depend on
        // (or pollute) the user's git config.
        let commit = try await GitRunner.run(
            args: [
                "-c", "user.name=graftty-presence",
                "-c", "user.email=presence@graftty.invalid",
                "commit-tree", tree, "-m", json,
            ],
            at: repoPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Force: each publish replaces the previous commit (no parent chain).
        _ = try await GitRunner.run(
            args: ["push", "--quiet", "--force", "origin", "\(commit):\(refName(slug: slug))"],
            at: repoPath
        )
    }

    /// @spec SYNC-2.2 (behavioral spec on PresenceRefSyncTests)
    public static func fetchAll(repoPath: String) async throws -> [PresenceDocument] {
        _ = try await GitRunner.run(
            args: [
                "fetch", "--quiet", "--force", "--prune", "origin",
                "+refs/graftty/presence/*:refs/graftty/presence/*",
            ],
            at: repoPath
        )
        let refList = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname)", "refs/graftty/presence/"],
            at: repoPath
        )
        var docs: [PresenceDocument] = []
        for ref in refList.split(separator: "\n").map(String.init) where !ref.isEmpty {
            guard let message = try? await GitRunner.run(
                args: ["show", "-s", "--format=%B", ref], at: repoPath
            ) else { continue }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip undecodable refs (foreign tools, future versions) rather
            // than failing the whole fetch.
            if let doc = try? PresenceDocument.decode(Data(trimmed.utf8)) {
                docs.append(doc)
            }
        }
        return docs
    }

    /// @spec SYNC-2.3 (behavioral spec on PresenceRefSyncTests)
    public static func delete(slug: String, repoPath: String) async throws {
        _ = try await GitRunner.run(
            args: ["push", "--quiet", "origin", ":\(refName(slug: slug))"],
            at: repoPath
        )
        // Drop the local mirror immediately as well.
        _ = try? await GitRunner.run(
            args: ["update-ref", "-d", refName(slug: slug)], at: repoPath
        )
    }
}
```

Note for the implementer: confirm `GitRunner.run(args:at:)` returns the stdout `String` and throws on non-zero exit (see `GitWorktreeDiscovery.discover` for the canonical call). If a fetch with zero matching refs exits non-zero on some git versions, switch that call to `GitRunner.captureAll` and only treat exit codes other than 0 as throwing after checking stderr — but plain `git fetch` with a non-matching wildcard refspec exits 0, so this should not be needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PresenceRefSyncTests`
Expected: 3 PASS (these hit real git and a bare upstream; they're integration tests, expect a few seconds).

- [ ] **Step 5: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Presence/PresenceRefSync.swift Tests/GrafttyKitTests/Presence/PresenceRefSyncTests.swift SPECS.md
git commit -m "feat(SYNC-2.1, SYNC-2.2, SYNC-2.3): presence ref publish/fetch/delete over origin"
```

---

### Task 4: RepoEntry.presenceSharingEnabled flag

**Files:**
- Modify: `Sources/GrafttyKit/Model/RepoEntry.swift`
- Test: `Tests/GrafttyKitTests/Presence/RepoEntryPresenceFlagTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry — presence sharing flag")
struct RepoEntryPresenceFlagTests {
    @Test("@spec SYNC-4.1: If a persisted RepoEntry predates presence sharing, then the application shall decode presenceSharingEnabled as false.")
    func legacyDecodeDefaultsToFalse() throws {
        // A minimal legacy payload without the new key.
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/repo",
         "displayName":"repo","isCollapsed":false,"worktrees":[],"isGitTracked":true}
        """
        let entry = try JSONDecoder().decode(RepoEntry.self, from: Data(legacy.utf8))
        #expect(entry.presenceSharingEnabled == false)
    }

    @Test("presenceSharingEnabled round-trips when set.")
    func flagRoundTrips() throws {
        var entry = RepoEntry(path: "/tmp/repo", displayName: "repo")
        entry.presenceSharingEnabled = true
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.presenceSharingEnabled == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RepoEntryPresenceFlagTests`
Expected: FAIL — `presenceSharingEnabled` not defined. (If `legacyDecodeDefaultsToFalse` fails on a *different* missing key, adjust the legacy JSON to include whatever other keys `RepoEntry`'s decoder requires — inspect the existing struct first.)

- [ ] **Step 3: Implement the flag**

In `Sources/GrafttyKit/Model/RepoEntry.swift`, add the stored property with a default:

```swift
/// @spec SYNC-4.1
/// Opt-in: while false (the default), the application shall neither publish
/// presence for this repo nor fetch teammates' presence refs.
public var presenceSharingEnabled: Bool
```

Initialize it to `false` in `init` (add `presenceSharingEnabled: Bool = false` as a defaulted parameter, assigned last).

For backwards-compatible decoding: if `RepoEntry` already has a custom `init(from:)`, add `presenceSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .presenceSharingEnabled) ?? false`. If it uses synthesized Codable, add a custom `init(from decoder:)` that decodes every existing field exactly as synthesized would (use `decodeIfPresent` with defaults only for fields that already tolerate absence — mirror how `WorktreeEntry.init(from:)` handles its post-1.0 fields) plus the new flag via `decodeIfPresent ?? false`. Keep encoding synthesized.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RepoEntryPresenceFlagTests`
Expected: 2 PASS.

Also run: `swift test --filter RepoEntry` and `swift test --filter AppState` to confirm no existing persistence tests regressed.

- [ ] **Step 5: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Model/RepoEntry.swift Tests/GrafttyKitTests/Presence/RepoEntryPresenceFlagTests.swift SPECS.md
git commit -m "feat(SYNC-4.1): opt-in presenceSharingEnabled flag on RepoEntry"
```

---

### Task 5: TeamPresenceSync service + store

**Files:**
- Create: `Sources/GrafttyKit/Presence/TeamPresenceSync.swift`
- Test: `Tests/GrafttyKitTests/Presence/TeamPresenceSyncTests.swift`

- [ ] **Step 1: Write the failing tests**

These use injected publisher/fetcher closures (no git), plus one end-to-end git test reusing Task 3's machinery.

```swift
import Testing
import Foundation
@testable import GrafttyKit

@MainActor
@Suite("TeamPresenceSync — tick behavior")
struct TeamPresenceSyncTests {
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeRepo(path: String = "/tmp/repo", sharing: Bool) -> RepoEntry {
        var repo = RepoEntry(path: path, displayName: "repo")
        repo.presenceSharingEnabled = sharing
        var wt = WorktreeEntry(path: path + "/wt/feature-x", branch: "feature-x")
        wt.state = .running
        repo.worktrees = [wt]
        return repo
    }

    private func makeSync(
        store: TeamPresenceSyncStore,
        identity: PresenceIdentity = PresenceIdentity(name: "Ben", email: "ben@btucker.net"),
        published: PublishLog = PublishLog(),
        fetchResult: [PresenceDocument] = []
    ) -> TeamPresenceSync {
        TeamPresenceSync(
            store: store,
            identityProvider: { _ in identity },
            publisher: { doc, slug, repoPath in await published.append((doc, slug, repoPath)) },
            fetcher: { _ in fetchResult },
            now: { Self.now }
        )
    }

    @Test("@spec SYNC-3.1: While presence sharing is disabled for a repo, the application shall neither publish nor fetch presence for that repo.")
    func disabledRepoIsSkipped() async {
        let store = TeamPresenceSyncStore()
        let published = PublishLog()
        let sync = makeSync(store: store, published: published,
                            fetchResult: [PresenceDocument(version: 1, user: "Sarah", email: "s@x.io", updatedAt: Self.now, worktrees: [])])
        await sync.tick(repos: [makeRepo(sharing: false)])
        #expect(await published.count == 0)
        #expect(store.remoteWorktrees.isEmpty)
    }

    @Test("@spec SYNC-3.2: When updating the remote-worktree store, the application shall exclude the local user's own presence document.")
    func ownDocumentExcluded() async {
        let store = TeamPresenceSyncStore()
        let mine = PresenceDocument(version: 1, user: "Ben", email: "ben@btucker.net", updatedAt: Self.now,
                                    worktrees: [.init(name: "multi-user", branch: "multi-user", state: "running")])
        let theirs = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com", updatedAt: Self.now,
                                      worktrees: [.init(name: "auth-refactor", branch: "auth-refactor", state: "running")])
        let sync = makeSync(store: store, fetchResult: [mine, theirs])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.count == 1)
        #expect(entries.first?.ownerName == "Sarah")
        #expect(entries.first?.branch == "auth-refactor")
    }

    @Test("@spec SYNC-3.3: If the published worktree set is unchanged and the last publish is younger than the 10-minute heartbeat interval, then the application shall not push again; once the heartbeat interval elapses, the application shall republish so the document's updatedAt outruns teammates' staleness cutoff.")
    func unchangedDocRepublishedOnlyAfterHeartbeat() async {
        let store = TeamPresenceSyncStore()
        let published = PublishLog()
        let clock = MutableClock(now: Self.now)
        let sync = TeamPresenceSync(
            store: store,
            identityProvider: { _ in PresenceIdentity(name: "Ben", email: "ben@btucker.net") },
            publisher: { doc, slug, repoPath in await published.append((doc, slug, repoPath)) },
            fetcher: { _ in [] },
            now: { clock.now }
        )
        let repo = makeRepo(sharing: true)

        await sync.tick(repos: [repo])           // initial publish
        await sync.tick(repos: [repo])           // unchanged, fresh → skipped
        #expect(await published.count == 1)

        clock.advance(by: TeamPresenceSync.heartbeatInterval + 1)
        await sync.tick(repos: [repo])           // unchanged but heartbeat due → republish
        #expect(await published.count == 2)
    }

    @Test("@spec SYNC-3.4: If a fetched presence document is older than 30 minutes, then the application shall omit it from the remote-worktree store.")
    func staleDocumentsOmitted() async {
        let store = TeamPresenceSyncStore()
        let fresh = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com",
                                     updatedAt: Self.now.addingTimeInterval(-60),
                                     worktrees: [.init(name: "fresh", branch: "fresh", state: "idle")])
        let stale = PresenceDocument(version: 1, user: "Marco", email: "marco@example.com",
                                     updatedAt: Self.now.addingTimeInterval(-31 * 60),
                                     worktrees: [.init(name: "old", branch: "old", state: "idle")])
        let sync = makeSync(store: store, fetchResult: [fresh, stale])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.map(\.ownerName) == ["Sarah"])
    }

    @Test("Remote entries are sorted by (owner, name) for stable rendering.")
    func entriesSorted() async {
        let store = TeamPresenceSyncStore()
        let sarah = PresenceDocument(version: 1, user: "Sarah", email: "sarah@example.com", updatedAt: Self.now,
                                     worktrees: [.init(name: "zeta", branch: "zeta", state: "idle"),
                                                 .init(name: "alpha", branch: "alpha", state: "idle")])
        let marco = PresenceDocument(version: 1, user: "Marco", email: "marco@example.com", updatedAt: Self.now,
                                     worktrees: [.init(name: "beta", branch: "beta", state: "idle")])
        let sync = makeSync(store: store, fetchResult: [sarah, marco])
        await sync.tick(repos: [makeRepo(sharing: true)])

        let entries = store.remoteWorktrees["/tmp/repo"] ?? []
        #expect(entries.map(\.name) == ["beta", "alpha", "zeta"])
    }
}

/// Thread-safe publish-call recorder for tests.
actor PublishLog {
    private(set) var calls: [(doc: PresenceDocument, slug: String, repoPath: String)] = []
    func append(_ call: (PresenceDocument, String, String)) { calls.append(call) }
    var count: Int { calls.count }
}

/// Advanceable clock for heartbeat tests. @unchecked Sendable is fine here:
/// test ticks are awaited sequentially, never concurrent.
final class MutableClock: @unchecked Sendable {
    private(set) var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamPresenceSyncTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import SwiftUI

/// One teammate worktree as rendered in the sidebar.
public struct RemoteWorktreePresence: Sendable, Equatable, Identifiable {
    public let ownerName: String
    public let ownerSlug: String
    public let name: String
    public let branch: String
    /// "running" | "idle"
    public let state: String
    public let updatedAt: Date

    public var id: String { "\(ownerSlug)/\(name)" }

    public init(ownerName: String, ownerSlug: String, name: String, branch: String, state: String, updatedAt: Date) {
        self.ownerName = ownerName
        self.ownerSlug = ownerSlug
        self.name = name
        self.branch = branch
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Observable store the sidebar reads: repoPath → teammates' worktrees.
@MainActor
public final class TeamPresenceSyncStore: ObservableObject {
    @Published public private(set) var remoteWorktrees: [String: [RemoteWorktreePresence]] = [:]

    public init() {}

    func update(repoPath: String, entries: [RemoteWorktreePresence]) {
        remoteWorktrees[repoPath] = entries
    }

    func clear(repoPath: String) {
        remoteWorktrees.removeValue(forKey: repoPath)
    }
}

/// Periodically publishes this user's presence and fetches teammates' for
/// every repo with sharing enabled. Best-effort: a failed publish or fetch is
/// retried on the next tick; presence is ambient data, never load-bearing.
@MainActor
public final class TeamPresenceSync {
    public typealias IdentityProvider = @Sendable (_ repoPath: String) async throws -> PresenceIdentity
    public typealias Publisher = @Sendable (_ doc: PresenceDocument, _ slug: String, _ repoPath: String) async throws -> Void
    public typealias Fetcher = @Sendable (_ repoPath: String) async throws -> [PresenceDocument]

    /// @spec SYNC-3.4 (behavioral spec on TeamPresenceSyncTests)
    public static let staleAfter: TimeInterval = 30 * 60
    /// @spec SYNC-3.3 (behavioral spec on TeamPresenceSyncTests)
    /// Unchanged documents are republished at this cadence so updatedAt stays
    /// ahead of teammates' staleAfter cutoff while we're alive.
    public static let heartbeatInterval: TimeInterval = 10 * 60

    private let store: TeamPresenceSyncStore
    private let identityProvider: IdentityProvider
    private let publisher: Publisher
    private let fetcher: Fetcher
    private let now: @Sendable () -> Date
    private var lastPublished: [String: (worktrees: [PresenceDocument.Worktree], at: Date)] = [:]

    public init(
        store: TeamPresenceSyncStore,
        identityProvider: @escaping IdentityProvider = { try await PresenceIdentity.load(repoPath: $0) },
        publisher: @escaping Publisher = { try await PresenceRefSync.publish($0, slug: $1, repoPath: $2) },
        fetcher: @escaping Fetcher = { try await PresenceRefSync.fetchAll(repoPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identityProvider = identityProvider
        self.publisher = publisher
        self.fetcher = fetcher
        self.now = now
    }

    public func start(ticker: PollingTickerLike, getRepos: @MainActor @escaping () -> [RepoEntry]) {
        ticker.start { [weak self] in
            await self?.tick(repos: getRepos())
        }
    }

    public func tick(repos: [RepoEntry]) async {
        for repo in repos {
            guard repo.presenceSharingEnabled, repo.isGitTracked else {
                store.clear(repoPath: repo.path)
                lastPublished.removeValue(forKey: repo.path)
                continue
            }
            guard let identity = try? await identityProvider(repo.path) else { continue }

            // Publish when the worktree set changed OR the heartbeat is due
            // (so updatedAt keeps outrunning teammates' staleness cutoff).
            let doc = PresenceDocument.build(
                user: identity.name, email: identity.email,
                worktrees: repo.worktrees, now: now()
            )
            let last = lastPublished[repo.path]
            let heartbeatDue = last.map { now().timeIntervalSince($0.at) > Self.heartbeatInterval } ?? true
            if last?.worktrees != doc.worktrees || heartbeatDue {
                if (try? await publisher(doc, identity.slug, repo.path)) != nil {
                    lastPublished[repo.path] = (doc.worktrees, now())
                }
            }

            // Fetch teammates.
            guard let docs = try? await fetcher(repo.path) else { continue }
            let cutoff = now().addingTimeInterval(-Self.staleAfter)
            let ownSlug = identity.slug
            let entries = docs
                .filter { PresenceIdentity.slug(forEmail: $0.email) != ownSlug }
                .filter { $0.updatedAt > cutoff }
                .flatMap { peer in
                    peer.worktrees.map {
                        RemoteWorktreePresence(
                            ownerName: peer.user,
                            ownerSlug: PresenceIdentity.slug(forEmail: peer.email),
                            name: $0.name, branch: $0.branch, state: $0.state,
                            updatedAt: peer.updatedAt
                        )
                    }
                }
                .sorted { ($0.ownerSlug, $0.name) < ($1.ownerSlug, $1.name) }
            store.update(repoPath: repo.path, entries: entries)
        }
    }
}
```

Notes for the implementer:
- `PollingTickerLike` is the protocol `WorktreeStatsStore.start(ticker:getRepos:)` accepts — find its definition (grep `protocol PollingTickerLike`) and mirror the exact `start` signature `WorktreeStatsStore` uses. If the protocol lives in the `Graftty` app target rather than `GrafttyKit`, copy whatever pattern `WorktreeStatsStore` actually uses — do not move files between targets without checking.
- If tuple comparison `($0.ownerSlug, $0.name) < (...)` displeases the compiler version, expand to `$0.ownerSlug == $1.ownerSlug ? $0.name < $1.name : $0.ownerSlug < $1.ownerSlug`.
- `import SwiftUI` is only needed if `ObservableObject`/`@Published` aren't already visible via another import in this target; `import Combine` is the minimal alternative — match what `WorktreeStatsStore` imports.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamPresenceSyncTests`
Expected: 6 PASS.

- [ ] **Step 5: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Presence/TeamPresenceSync.swift Tests/GrafttyKitTests/Presence/TeamPresenceSyncTests.swift SPECS.md
git commit -m "feat(SYNC-3.1..3.4): TeamPresenceSync polling service and observable store"
```

---

### Task 6: End-to-end integration test (two clones, real git)

**Files:**
- Create: `Tests/GrafttyKitTests/Presence/PresenceEndToEndTests.swift`

- [ ] **Step 1: Write the test (should pass immediately — this validates composition, not new code)**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@MainActor
@Suite("Presence — end to end over a real shared remote", .serialized)
struct PresenceEndToEndTests {
    @Test("Two clones of one upstream exchange presence through refs/graftty/presence/*.")
    func twoClonesExchangePresence() async throws {
        let (root, cloneA, upstream) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloneB = root.appendingPathComponent("cloneB")
        try shellInRepo("git clone \(upstream.path) \(cloneB.path)", at: root)
        try shellInRepo("git config user.name 'Ben' && git config user.email 'ben@btucker.net'", at: cloneA)
        try shellInRepo("git config user.name 'Sarah' && git config user.email 'sarah@example.com'", at: cloneB)

        // Sarah (cloneB) publishes via her own sync service.
        let storeB = TeamPresenceSyncStore()
        let syncB = TeamPresenceSync(store: storeB)
        var repoB = RepoEntry(path: cloneB.path, displayName: "repo")
        repoB.presenceSharingEnabled = true
        var wtB = WorktreeEntry(path: cloneB.path + "/wt/auth-refactor", branch: "auth-refactor")
        wtB.state = .running
        repoB.worktrees = [wtB]
        await syncB.tick(repos: [repoB])

        // Ben (cloneA) ticks and sees Sarah's worktree, not his own.
        let storeA = TeamPresenceSyncStore()
        let syncA = TeamPresenceSync(store: storeA)
        var repoA = RepoEntry(path: cloneA.path, displayName: "repo")
        repoA.presenceSharingEnabled = true
        var wtA = WorktreeEntry(path: cloneA.path + "/wt/multi-user", branch: "multi-user")
        wtA.state = .running
        repoA.worktrees = [wtA]
        await syncA.tick(repos: [repoA])

        let entries = storeA.remoteWorktrees[cloneA.path] ?? []
        #expect(entries.map(\.ownerName) == ["Sarah"])
        #expect(entries.map(\.branch) == ["auth-refactor"])
        #expect(entries.map(\.state) == ["running"])
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter PresenceEndToEndTests`
Expected: PASS. If it fails, the composition has a real bug — debug before proceeding (likely suspects: identity probe picking up global config, fetch refspec, slug mismatch).

- [ ] **Step 3: Commit**

```bash
scripts/generate-specs.py
git add Tests/GrafttyKitTests/Presence/PresenceEndToEndTests.swift SPECS.md
git commit -m "test: presence end-to-end exchange between two clones"
```

---

### Task 7: Sidebar — RemoteWorktreeRow + rendering + context-menu toggle

**Files:**
- Create: `Sources/Graftty/Views/RemoteWorktreeRow.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Create: `Tests/GrafttyTests/Specs/SyncTodo.swift` (inventory for the render spec)

SwiftUI rendering isn't covered by headless tests in this codebase; the render requirement is recorded as a disabled inventory spec, consistent with project convention.

- [ ] **Step 1: Add the inventory spec**

Create `Tests/GrafttyTests/Specs/SyncTodo.swift`:

```swift
// Inventory of unimplemented/untestable specs in the SYNC section.
// Promote entries to real @Tests before implementing the behavior.

import Testing

@Suite("SYNC — pending specs")
struct SyncTodo {
    @Test("""
@spec SYNC-5.1: While presence sharing is enabled for a repo, the sidebar shall render teammates' worktrees inside that repo's section with an owner badge and ambient (dimmed, non-interactive) styling.
""", .disabled("UI rendering; verified manually"))
    func sync_5_1() async throws { }
}
```

- [ ] **Step 2: Create the row view**

`Sources/Graftty/Views/RemoteWorktreeRow.swift` — ambient styling per the project's status-cue convention: dim opacity ladder and italics, **no saturated colors**.

```swift
import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// @spec SYNC-5.1 (rendering; inventory spec in SyncTodo.swift)
/// A teammate's worktree, rendered read-only and ambient: hollow person
/// icon, dimmed branch text, italic "running" hint, owner badge at the
/// trailing edge. Deliberately quieter than local rows.
struct RemoteWorktreeRow: View {
    let presence: RemoteWorktreePresence
    let theme: GhosttyTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person")
                .font(.caption)
                .foregroundColor(theme.sidebarDimIcon)
            Text(presence.branch)
                .foregroundColor(theme.sidebarSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if presence.state == "running" {
                Text("running")
                    .font(.caption)
                    .italic()
                    .foregroundColor(theme.sidebarSecondaryText)
            }
            Spacer()
            Text(presence.ownerName)
                .font(.caption)
                .foregroundColor(theme.sidebarSecondaryText)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(presence.ownerName)'s worktree \(presence.branch)")
    }
}
```

Check the exact theme property names against `WorktreeRow.swift` usage (`theme.sidebarDimIcon`, `theme.sidebarSecondaryText`) and use whatever that file actually uses for dim icon + secondary text.

- [ ] **Step 3: Render remote rows in SidebarView**

In `Sources/Graftty/Views/SidebarView.swift`:

1. Add a property alongside the existing stores the view receives:
   ```swift
   @ObservedObject var presenceStore: TeamPresenceSyncStore
   ```
2. In `repoSection(_:)`, after the `ForEach(repo.worktrees) { … }` block (inside the same `DisclosureGroup` content), append:
   ```swift
   ForEach(presenceStore.remoteWorktrees[repo.path] ?? []) { remote in
       RemoteWorktreeRow(presence: remote, theme: theme)
   }
   ```
   (Match how `theme` is named/accessed in this view.) Remote rows carry no `Button`, no drag/drop, no context menu — they are intentionally inert in P1.
3. Find every construction site of `SidebarView(` (grep; likely `MainWindow.swift` or `GrafttyApp.swift`) and pass the store through. Thread it the same way `statsStore`/`prStatusStore` reach the sidebar — follow the existing chain exactly.

- [ ] **Step 4: Add the repo context-menu toggle**

In the repo-level context menu in `SidebarView.swift` (the menu containing "Initialize Git Repository" / "Remove Repository"):

1. Add a closure property to the view, following the naming of existing action closures:
   ```swift
   let onToggleTeamSharing: (String) -> Void
   ```
2. Add a menu item after the existing items, only for `repo.isGitTracked` repos. Follow the existing menu-construction mechanism in this file (NSMenu item or SwiftUI `Button`, whichever the repo menu already uses):
   - Title: `repo.presenceSharingEnabled ? "Stop Sharing Worktrees with Team" : "Share Worktrees with Team"`
   - Action: `onToggleTeamSharing(repo.path)`
3. Implement the handler where the sidebar's other action closures are implemented (e.g. `MainWindow`), and thread it through the same construction sites updated in Step 3:
   ```swift
   func toggleTeamSharing(repoPath: String) {
       guard let idx = appState.repos.firstIndex(where: { $0.path == repoPath }) else { return }
       appState.repos[idx].presenceSharingEnabled.toggle()
       let enabled = appState.repos[idx].presenceSharingEnabled
       if enabled {
           // First publish/fetch without waiting a full poll interval.
           services.teamPresenceTicker?.pulse()
       } else {
           // @spec SYNC-2.3: leaving deletes our ref from origin (best-effort).
           Task {
               if let identity = try? await PresenceIdentity.load(repoPath: repoPath) {
                   try? await PresenceRefSync.delete(slug: identity.slug, repoPath: repoPath)
               }
           }
       }
   }
   ```
   Adapt `services.teamPresenceTicker` access to wherever this handler lives — if `services` isn't reachable there, route the pulse the same way other handlers reach tickers/stores (check how stop/delete-worktree handlers reach `services`).

- [ ] **Step 5: Build**

Run: `swift build`
Expected: clean build. Fix any threading/property-name mismatches by reading the surrounding code, not by changing the design.

- [ ] **Step 6: Regenerate specs and commit**

```bash
scripts/generate-specs.py
git add Sources/Graftty/Views/RemoteWorktreeRow.swift Sources/Graftty/Views/SidebarView.swift Tests/GrafttyTests/Specs/SyncTodo.swift SPECS.md
# plus whichever construction-site files were modified (MainWindow.swift etc.)
git add -A Sources/Graftty
git commit -m "feat(SYNC-5.1): render teammates' worktrees in sidebar; repo menu sharing toggle"
```

---

### Task 8: App wiring — service construction + ticker

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Construct store + service in AppServices**

In `AppServices` (around the other store constructions in `init`):

```swift
let teamPresenceSyncStore: TeamPresenceSyncStore
let teamPresenceSync: TeamPresenceSync
var teamPresenceTicker: PollingTicker?
```

and in `AppServices.init`:

```swift
let teamPresenceSyncStore = TeamPresenceSyncStore()
self.teamPresenceSyncStore = teamPresenceSyncStore
self.teamPresenceSync = TeamPresenceSync(store: teamPresenceSyncStore)
```

- [ ] **Step 2: Start the ticker in startup()**

Next to the `remoteBranchTicker` wiring in `GrafttyApp.startup()` (mirror its pattern exactly):

```swift
// SYNC: team presence publish/fetch. 60s cadence; presence is ambient,
// so it keeps polling while the app is backgrounded (teammates still
// see us, we still see them).
let teamPresenceTicker = PollingTicker(
    interval: .seconds(60),
    pauseWhenInactive: { false }
)
services.teamPresenceTicker = teamPresenceTicker
services.teamPresenceSync.start(
    ticker: teamPresenceTicker,
    getRepos: { binding.wrappedValue.repos }
)
```

(Use the same `binding`/`appState` accessor the adjacent ticker wirings use.)

- [ ] **Step 3: Pass the store to the sidebar**

Complete the threading started in Task 7 Step 3: `services.teamPresenceSyncStore` flows to `SidebarView`, and the `onToggleTeamSharing` handler is wired at the same site as `onStopWorktree`/`onDeleteWorktree`.

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: clean build, all tests pass (including all pre-existing suites).

- [ ] **Step 5: Regenerate specs, verify, and commit**

```bash
scripts/generate-specs.py --check   # should report SPECS.md current
git add -A Sources/Graftty SPECS.md
git commit -m "feat(SYNC): wire TeamPresenceSync ticker and store into app startup"
```

---

### Task 9: Manual smoke check (optional but recommended)

- [ ] With two local clones of a test repo (or this repo + a scratch bare remote), run the app, enable "Share Worktrees with Team" on a repo, and verify:
  1. `git ls-remote origin 'refs/graftty/presence/*'` shows your ref within ~60s (or immediately after toggle, via pulse).
  2. Publishing a fake teammate doc (run the `PresenceRefSync.publish` flow from a second clone with different `user.email`, e.g. via a tiny swift test or the Task 6 test repo) makes a dimmed row appear in the sidebar within ~60s.
  3. Toggling sharing off deletes the ref (`ls-remote` again) and clears remote rows.

---

## Self-review checklist (run after all tasks)

- All SYNC-* specs appear exactly once in `SPECS.md` (`scripts/generate-specs.py --check` passes).
- `swift test` fully green.
- No saturated status colors in `RemoteWorktreeRow` (dim/italic only).
- Presence never publishes for repos with `presenceSharingEnabled == false` (default).

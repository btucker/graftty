# Graftty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS terminal multiplexer that organizes persistent terminal sessions by git worktree, with an attention notification system.

**Architecture:** Three-layer Swift app — a pure model layer (AppState/RepoEntry/WorktreeEntry/SplitTree), a terminal manager bridging to libghostty, and a SwiftUI+AppKit UI layer. A separate CLI binary communicates with the app over a Unix domain socket.

**Tech Stack:** Swift, SwiftUI, AppKit, libghostty (via libghostty-spm), FSEvents, Unix domain sockets

---

## File Structure

```
Graftty/
├── Package.swift
├── Sources/
│   ├── GrafttyKit/                          # Shared library (model, git, notification)
│   │   ├── Model/
│   │   │   ├── TerminalID.swift              # UUID wrapper for terminal pane identity
│   │   │   ├── Attention.swift               # Attention overlay data
│   │   │   ├── SplitTree.swift               # Generic binary split tree (from Ghostty)
│   │   │   ├── WorktreeEntry.swift           # Worktree model + state enum
│   │   │   ├── RepoEntry.swift               # Repository model
│   │   │   └── AppState.swift                # Root state + persistence
│   │   ├── Git/
│   │   │   ├── GitRepoDetector.swift         # Classify path as repo/worktree/neither
│   │   │   ├── GitWorktreeDiscovery.swift    # Parse `git worktree list --porcelain`
│   │   │   └── WorktreeMonitor.swift         # FSEvents watchers for worktree changes
│   │   └── Notification/
│   │       ├── NotificationMessage.swift     # JSON message types for socket protocol
│   │       └── SocketServer.swift            # Unix domain socket listener
│   ├── Graftty/                             # macOS app executable
│   │   ├── GrafttyApp.swift                 # @main SwiftUI App entry point
│   │   ├── Terminal/
│   │   │   ├── GhosttyBridge.swift           # Swift wrappers for ghostty_app_t, ghostty_config_t
│   │   │   ├── SurfaceHandle.swift           # Wraps ghostty_surface_t + NSView
│   │   │   └── TerminalManager.swift         # Surface lifecycle, focus, GRAFTTY_SOCK
│   │   └── Views/
│   │       ├── MainWindow.swift              # Top-level NavigationSplitView layout
│   │       ├── BreadcrumbBar.swift           # Repo / branch / path context bar
│   │       ├── SidebarView.swift             # Repo tree with expand/collapse
│   │       ├── WorktreeRow.swift             # Single worktree row with state indicator
│   │       ├── SplitContainerView.swift      # Draggable split view (from Ghostty)
│   │       ├── SurfaceViewWrapper.swift      # NSViewRepresentable for terminal surface
│   │       └── TerminalContentView.swift     # Recursive split tree → terminal views
│   └── GrafttyCLI/                          # CLI tool
│       ├── CLI.swift                         # Argument parsing + main entry
│       ├── WorktreeResolver.swift            # Walk up from PWD to find worktree
│       └── SocketClient.swift                # Connect to app socket, send message
├── Tests/
│   └── GrafttyKitTests/
│       ├── Model/
│       │   ├── SplitTreeTests.swift
│       │   ├── WorktreeEntryTests.swift
│       │   └── AppStateTests.swift
│       ├── Git/
│       │   ├── GitRepoDetectorTests.swift
│       │   └── GitWorktreeDiscoveryTests.swift
│       └── Notification/
│           ├── NotificationMessageTests.swift
│           └── SocketIntegrationTests.swift
```

**Key decisions:**
- `GrafttyKit` is a library shared by both the app and CLI (model types, git logic, socket protocol)
- The app target (`Graftty`) holds everything that depends on AppKit/SwiftUI/libghostty
- The CLI target (`GrafttyCLI`) is a lightweight executable depending only on `GrafttyKit` and Foundation
- Tests cover `GrafttyKit` only — the app and CLI are tested manually and via integration tests

---

### Task 1: Project Scaffolding

**Files:**
- Create: `Package.swift`
- Create: `Sources/GrafttyKit/Model/TerminalID.swift` (placeholder to make target compile)
- Create: `Sources/Graftty/GrafttyApp.swift` (minimal @main)
- Create: `Sources/GrafttyCLI/CLI.swift` (minimal main)
- Create: `Tests/GrafttyKitTests/Model/SplitTreeTests.swift` (placeholder)

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Graftty",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Graftty", targets: ["Graftty"]),
        .executable(name: "graftty", targets: ["GrafttyCLI"]),
        .library(name: "GrafttyKit", targets: ["GrafttyKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "GrafttyKit",
            dependencies: []
        ),
        .executableTarget(
            name: "Graftty",
            dependencies: [
                "GrafttyKit",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(
            name: "GrafttyCLI",
            dependencies: [
                "GrafttyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GrafttyKitTests",
            dependencies: ["GrafttyKit"]
        ),
    ]
)
```

- [ ] **Step 2: Create minimal source files to make all targets compile**

`Sources/GrafttyKit/Model/TerminalID.swift`:
```swift
import Foundation

public struct TerminalID: Hashable, Codable, Identifiable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }
}
```

`Sources/Graftty/GrafttyApp.swift`:
```swift
import SwiftUI

@main
struct GrafttyApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Graftty")
        }
    }
}
```

`Sources/GrafttyCLI/CLI.swift`:
```swift
import ArgumentParser
import Foundation

@main
struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI"
    )

    func run() throws {
        print("graftty CLI")
    }
}
```

`Tests/GrafttyKitTests/Model/SplitTreeTests.swift`:
```swift
import Testing
@testable import GrafttyKit

@Suite("SplitTree Tests")
struct SplitTreeTests {
    @Test func placeholder() {
        #expect(true)
    }
}
```

- [ ] **Step 3: Verify the project resolves dependencies and builds**

Run: `cd /Users/btucker/projects/graftty && swift build 2>&1 | tail -5`
Expected: Build succeeds (or resolves dependencies then succeeds)

Note: The libghostty-spm dependency may require adjustments depending on the current published version. Check https://github.com/Lakr233/libghostty-spm/releases for the latest tag and update the `from:` version accordingly. If the package name or product differs, update Package.swift to match.

- [ ] **Step 4: Verify tests run**

Run: `swift test 2>&1 | tail -5`
Expected: 1 test passes

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "feat: scaffold project with GrafttyKit, app, and CLI targets"
```

---

### Task 2: SplitTree

Port the generic `SplitTree` from Ghostty's `macos/Sources/Features/Splits/SplitTree.swift`. This is the core data structure for terminal pane layout. It needs to be adapted to work without Ghostty's `Notification` extensions and made `public` for use across modules.

**Reference:** https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Splits/SplitTree.swift

**Files:**
- Create: `Sources/GrafttyKit/Model/SplitTree.swift`
- Modify: `Tests/GrafttyKitTests/Model/SplitTreeTests.swift`

- [ ] **Step 1: Write failing tests for SplitTree basics**

`Tests/GrafttyKitTests/Model/SplitTreeTests.swift`:
```swift
import Testing
@testable import GrafttyKit

@Suite("SplitTree Tests")
struct SplitTreeTests {

    @Test func singleLeaf() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.root != nil)
        if case .leaf(let leafID) = tree.root {
            #expect(leafID == id)
        } else {
            Issue.record("Expected leaf node")
        }
    }

    @Test func horizontalSplit() {
        let left = TerminalID()
        let right = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        )))
        #expect(tree.leafCount == 2)
    }

    @Test func insertSplitAtLeaf() {
        let original = TerminalID()
        let tree = SplitTree(root: .leaf(original))
        let newID = TerminalID()
        let updated = tree.inserting(newID, at: original, direction: .horizontal)
        #expect(updated.leafCount == 2)
    }

    @Test func removeLeaf() {
        let left = TerminalID()
        let right = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        )))
        let updated = tree.removing(left)
        #expect(updated.leafCount == 1)
        if case .leaf(let remaining) = updated.root {
            #expect(remaining == right)
        } else {
            Issue.record("Expected single leaf after removal")
        }
    }

    @Test func removeLastLeafReturnsNilRoot() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        let updated = tree.removing(id)
        #expect(updated.root == nil)
    }

    @Test func allLeaves() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(b),
                right: .leaf(c)
            ))
        )))
        let leaves = tree.allLeaves
        #expect(leaves.count == 3)
        #expect(leaves.contains(a))
        #expect(leaves.contains(b))
        #expect(leaves.contains(c))
    }

    @Test func codableRoundTrip() throws {
        let a = TerminalID()
        let b = TerminalID()
        let tree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.6,
            left: .leaf(a),
            right: .leaf(b)
        )))
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)
        #expect(decoded.leafCount == 2)
        #expect(decoded.allLeaves.contains(a))
        #expect(decoded.allLeaves.contains(b))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SplitTreeTests 2>&1 | tail -10`
Expected: Compilation errors (SplitTree not defined)

- [ ] **Step 3: Implement SplitTree**

`Sources/GrafttyKit/Model/SplitTree.swift`:
```swift
import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct SplitTree: Codable, Sendable, Equatable {
    public let root: Node?

    public init(root: Node?) {
        self.root = root
    }

    public indirect enum Node: Codable, Sendable, Equatable {
        case leaf(TerminalID)
        case split(Split)

        public struct Split: Codable, Sendable, Equatable {
            public let direction: SplitDirection
            public let ratio: Double
            public let left: Node
            public let right: Node

            public init(direction: SplitDirection, ratio: Double, left: Node, right: Node) {
                self.direction = direction
                self.ratio = ratio
                self.left = left
                self.right = right
            }

            public func withRatio(_ newRatio: Double) -> Split {
                Split(direction: direction, ratio: newRatio, left: left, right: right)
            }
        }
    }

    // MARK: - Queries

    public var leafCount: Int {
        guard let root else { return 0 }
        return root.leafCount
    }

    public var allLeaves: [TerminalID] {
        guard let root else { return [] }
        return root.allLeaves
    }

    // MARK: - Mutations (return new trees)

    /// Insert a new leaf adjacent to the target, splitting in the given direction.
    public func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.inserting(newLeaf, at: target, direction: direction))
    }

    /// Remove a leaf. Its sibling takes the parent split's place.
    public func removing(_ target: TerminalID) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.removing(target))
    }

    /// Update the ratio of the split containing the given leaf on its left/top side.
    public func updatingRatio(for target: TerminalID, ratio: Double) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.updatingRatio(for: target, ratio: ratio))
    }
}

extension SplitTree.Node {
    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(let s):
            return s.left.leafCount + s.right.leafCount
        }
    }

    var allLeaves: [TerminalID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let s):
            return s.left.allLeaves + s.right.allLeaves
        }
    }

    func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree.Node {
        switch self {
        case .leaf(let id):
            if id == target {
                return .split(.init(
                    direction: direction,
                    ratio: 0.5,
                    left: .leaf(id),
                    right: .leaf(newLeaf)
                ))
            }
            return self
        case .split(let s):
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.inserting(newLeaf, at: target, direction: direction),
                right: s.right.inserting(newLeaf, at: target, direction: direction)
            ))
        }
    }

    func removing(_ target: TerminalID) -> SplitTree.Node? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let s):
            let newLeft = s.left.removing(target)
            let newRight = s.right.removing(target)
            if newLeft == nil { return newRight }
            if newRight == nil { return newLeft }
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    func updatingRatio(for target: TerminalID, ratio: Double) -> SplitTree.Node {
        switch self {
        case .leaf:
            return self
        case .split(let s):
            if case .leaf(let leftID) = s.left, leftID == target {
                return .split(s.withRatio(ratio))
            }
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.updatingRatio(for: target, ratio: ratio),
                right: s.right.updatingRatio(for: target, ratio: ratio)
            ))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SplitTreeTests 2>&1 | tail -10`
Expected: All 7 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Model/SplitTree.swift Tests/GrafttyKitTests/Model/SplitTreeTests.swift
git commit -m "feat: add SplitTree generic binary split tree data structure"
```

---

### Task 3: Core Model Types

**Files:**
- Modify: `Sources/GrafttyKit/Model/TerminalID.swift` (already exists, may need tweaks)
- Create: `Sources/GrafttyKit/Model/Attention.swift`
- Create: `Sources/GrafttyKit/Model/WorktreeEntry.swift`
- Create: `Sources/GrafttyKit/Model/RepoEntry.swift`
- Create: `Tests/GrafttyKitTests/Model/WorktreeEntryTests.swift`

- [ ] **Step 1: Write failing tests for model types**

`Tests/GrafttyKitTests/Model/WorktreeEntryTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("WorktreeEntry Tests")
struct WorktreeEntryTests {

    @Test func newEntryIsClosedState() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "feature/foo")
        #expect(entry.state == .closed)
        #expect(entry.attention == nil)
    }

    @Test func attentionCanBeSet() {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        entry.attention = Attention(text: "Build failed", timestamp: Date())
        #expect(entry.attention?.text == "Build failed")
    }

    @Test func attentionWithAutoClear() {
        let attn = Attention(text: "Done", timestamp: Date(), clearAfter: 10)
        #expect(attn.clearAfter == 10)
    }

    @Test func splitTreeDefaultsToNil() {
        let entry = WorktreeEntry(path: "/tmp/worktree", branch: "main")
        #expect(entry.splitTree.root == nil)
    }

    @Test func codableRoundTrip() throws {
        var entry = WorktreeEntry(path: "/tmp/worktree", branch: "feature/bar")
        entry.state = .running
        let id = TerminalID()
        entry.splitTree = SplitTree(root: .leaf(id))

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorktreeEntry.self, from: data)
        #expect(decoded.path == "/tmp/worktree")
        #expect(decoded.branch == "feature/bar")
        #expect(decoded.state == .running)
        #expect(decoded.splitTree.leafCount == 1)
    }

    @Test func repoEntryContainsWorktrees() {
        let main = WorktreeEntry(path: "/tmp/repo", branch: "main")
        let feature = WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature/x")
        let repo = RepoEntry(
            path: "/tmp/repo",
            displayName: "my-repo",
            worktrees: [main, feature]
        )
        #expect(repo.worktrees.count == 2)
        #expect(repo.displayName == "my-repo")
    }

    @Test func repoEntryCodeableRoundTrip() throws {
        let main = WorktreeEntry(path: "/tmp/repo", branch: "main")
        let repo = RepoEntry(path: "/tmp/repo", displayName: "my-repo", worktrees: [main])
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.path == "/tmp/repo")
        #expect(decoded.worktrees.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorktreeEntryTests 2>&1 | tail -10`
Expected: Compilation errors (types not defined)

- [ ] **Step 3: Implement Attention**

`Sources/GrafttyKit/Model/Attention.swift`:
```swift
import Foundation

public struct Attention: Codable, Sendable, Equatable {
    public let text: String
    public let timestamp: Date
    public let clearAfter: TimeInterval?

    public init(text: String, timestamp: Date, clearAfter: TimeInterval? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.clearAfter = clearAfter
    }
}
```

- [ ] **Step 4: Implement WorktreeEntry**

`Sources/GrafttyKit/Model/WorktreeEntry.swift`:
```swift
import Foundation

public enum WorktreeState: String, Codable, Sendable {
    case closed
    case running
    case stale
}

public struct WorktreeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var branch: String
    public var state: WorktreeState
    public var attention: Attention?
    public var splitTree: SplitTree
    public var focusedTerminalID: TerminalID?

    public init(
        path: String,
        branch: String,
        state: WorktreeState = .closed,
        attention: Attention? = nil,
        splitTree: SplitTree = SplitTree(root: nil)
    ) {
        self.id = UUID()
        self.path = path
        self.branch = branch
        self.state = state
        self.attention = attention
        self.splitTree = splitTree
        self.focusedTerminalID = nil
    }
}
```

- [ ] **Step 5: Implement RepoEntry**

`Sources/GrafttyKit/Model/RepoEntry.swift`:
```swift
import Foundation

public struct RepoEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var displayName: String
    public var isCollapsed: Bool
    public var worktrees: [WorktreeEntry]

    public init(
        path: String,
        displayName: String,
        isCollapsed: Bool = false,
        worktrees: [WorktreeEntry] = []
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.isCollapsed = isCollapsed
        self.worktrees = worktrees
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter WorktreeEntryTests 2>&1 | tail -10`
Expected: All 6 tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Model/ Tests/GrafttyKitTests/Model/WorktreeEntryTests.swift
git commit -m "feat: add core model types — Attention, WorktreeEntry, RepoEntry"
```

---

### Task 4: AppState & Persistence

**Files:**
- Create: `Sources/GrafttyKit/Model/AppState.swift`
- Create: `Tests/GrafttyKitTests/Model/AppStateTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/GrafttyKitTests/Model/AppStateTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("AppState Tests")
struct AppStateTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyStateHasNoRepos() {
        let state = AppState()
        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)
    }

    @Test func addRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ])
        state.addRepo(repo)
        #expect(state.repos.count == 1)
    }

    @Test func addDuplicateRepoIsIgnored() {
        var state = AppState()
        let repo1 = RepoEntry(path: "/tmp/repo", displayName: "repo")
        let repo2 = RepoEntry(path: "/tmp/repo", displayName: "repo-dup")
        state.addRepo(repo1)
        state.addRepo(repo2)
        #expect(state.repos.count == 1)
    }

    @Test func removeRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo")
        state.addRepo(repo)
        state.removeRepo(atPath: "/tmp/repo")
        #expect(state.repos.isEmpty)
    }

    @Test func saveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repo"
        state.sidebarWidth = 280

        try state.save(to: dir)

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.count == 1)
        #expect(loaded.repos[0].path == "/tmp/repo")
        #expect(loaded.selectedWorktreePath == "/tmp/repo")
        #expect(loaded.sidebarWidth == 280)
    }

    @Test func loadFromEmptyDirReturnsDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.isEmpty)
    }

    @Test func worktreeForPathFindsCorrectEntry() {
        var state = AppState()
        let wt = WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature/x")
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            wt,
        ]))
        let found = state.worktree(forPath: "/tmp/worktrees/feature")
        #expect(found?.branch == "feature/x")
    }

    @Test func worktreeForPathReturnsNilWhenNotFound() {
        let state = AppState()
        #expect(state.worktree(forPath: "/nonexistent") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStateTests 2>&1 | tail -10`
Expected: Compilation errors

- [ ] **Step 3: Implement AppState**

`Sources/GrafttyKit/Model/AppState.swift`:
```swift
import Foundation

public struct WindowFrame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 100, y: Double = 100, width: Double = 1400, height: Double = 900) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public var repos: [RepoEntry]
    public var selectedWorktreePath: String?
    public var windowFrame: WindowFrame
    public var sidebarWidth: Double

    public init(
        repos: [RepoEntry] = [],
        selectedWorktreePath: String? = nil,
        windowFrame: WindowFrame = WindowFrame(),
        sidebarWidth: Double = 240
    ) {
        self.repos = repos
        self.selectedWorktreePath = selectedWorktreePath
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
    }

    // MARK: - Repo management

    public mutating func addRepo(_ repo: RepoEntry) {
        guard !repos.contains(where: { $0.path == repo.path }) else { return }
        repos.append(repo)
    }

    public mutating func removeRepo(atPath path: String) {
        repos.removeAll { $0.path == path }
    }

    // MARK: - Lookup

    public func worktree(forPath path: String) -> WorktreeEntry? {
        for repo in repos {
            if let wt = repo.worktrees.first(where: { $0.path == path }) {
                return wt
            }
        }
        return nil
    }

    public func repo(forWorktreePath path: String) -> RepoEntry? {
        repos.first { repo in
            repo.worktrees.contains { $0.path == path }
        }
    }

    // MARK: - Persistence

    private static let fileName = "state.json"

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func load(from directory: URL) throws -> AppState {
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppState()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppState.self, from: data)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppStateTests 2>&1 | tail -10`
Expected: All 8 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Model/AppState.swift Tests/GrafttyKitTests/Model/AppStateTests.swift
git commit -m "feat: add AppState with persistence to state.json"
```

---

### Task 5: Git Repo Detection

Determine whether a given filesystem path is a git repository root, a linked worktree, or neither. This is used both when adding repos to the sidebar and by the CLI to resolve the current worktree.

**Files:**
- Create: `Sources/GrafttyKit/Git/GitRepoDetector.swift`
- Create: `Tests/GrafttyKitTests/Git/GitRepoDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/GrafttyKitTests/Git/GitRepoDetectorTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitRepoDetector Tests")
struct GitRepoDetectorTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func shell(_ command: String, at dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitRepoDetectorTestError.shellFailed(command, process.terminationStatus)
        }
    }

    enum GitRepoDetectorTestError: Error {
        case shellFailed(String, Int32)
    }

    @Test func detectsRepoRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try shell("git init && git commit --allow-empty -m 'init'", at: dir)

        let result = try GitRepoDetector.detect(path: dir.path)
        #expect(result == .repoRoot(dir.path))
    }

    @Test func detectsWorktree() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        let wtDir = dir.appendingPathComponent("worktree-feature")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try shell("git init && git commit --allow-empty -m 'init'", at: repoDir)
        try shell("git worktree add \(wtDir.path) -b feature", at: repoDir)

        let result = try GitRepoDetector.detect(path: wtDir.path)
        if case .worktree(let worktreePath, let repoPath) = result {
            #expect(worktreePath == wtDir.path)
            #expect(repoPath == repoDir.path)
        } else {
            Issue.record("Expected .worktree, got \(result)")
        }
    }

    @Test func detectsNotARepo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try GitRepoDetector.detect(path: dir.path)
        #expect(result == .notARepo)
    }

    @Test func detectsSubdirectoryOfRepo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try shell("git init && git commit --allow-empty -m 'init'", at: dir)
        let subDir = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let result = try GitRepoDetector.detect(path: subDir.path)
        #expect(result == .repoRoot(dir.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitRepoDetectorTests 2>&1 | tail -10`
Expected: Compilation errors

- [ ] **Step 3: Implement GitRepoDetector**

`Sources/GrafttyKit/Git/GitRepoDetector.swift`:
```swift
import Foundation

public enum GitPathType: Equatable, Sendable {
    case repoRoot(String)
    case worktree(worktreePath: String, repoPath: String)
    case notARepo
}

public enum GitRepoDetector {

    /// Walk up from `path` to determine if it's inside a git repo or worktree.
    /// Returns the classification and the resolved root path.
    public static func detect(path: String) throws -> GitPathType {
        var current = URL(fileURLWithPath: path).standardized

        while true {
            let gitPath = current.appendingPathComponent(".git")

            if FileManager.default.fileExists(atPath: gitPath.path) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir)

                if isDir.boolValue {
                    // .git is a directory → this is a repo root
                    return .repoRoot(current.path)
                } else {
                    // .git is a file → this is a linked worktree
                    // Contents: "gitdir: /path/to/repo/.git/worktrees/<name>"
                    let contents = try String(contentsOf: gitPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard contents.hasPrefix("gitdir: ") else {
                        return .notARepo
                    }
                    let gitDir = String(contents.dropFirst("gitdir: ".count))
                    // Walk up from gitdir to find the repo root
                    // gitDir looks like: /path/to/repo/.git/worktrees/<name>
                    // We need: /path/to/repo
                    let repoPath = resolveRepoRoot(fromGitDir: gitDir)
                    return .worktree(worktreePath: current.path, repoPath: repoPath)
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                // Reached filesystem root
                return .notARepo
            }
            current = parent
        }
    }

    /// Given a gitdir path like `/repo/.git/worktrees/foo`, resolve to the repo root `/repo`.
    private static func resolveRepoRoot(fromGitDir gitDir: String) -> String {
        // The gitdir for a worktree is: <repo>/.git/worktrees/<name>
        // Walk up to find the .git directory, then its parent is the repo root.
        var url = URL(fileURLWithPath: gitDir).standardized

        // Walk up until we find a component that IS .git
        while url.lastPathComponent != ".git" && url.path != "/" {
            url = url.deletingLastPathComponent()
        }

        // Parent of .git is the repo root
        return url.deletingLastPathComponent().path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitRepoDetectorTests 2>&1 | tail -10`
Expected: All 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/GitRepoDetector.swift Tests/GrafttyKitTests/Git/GitRepoDetectorTests.swift
git commit -m "feat: add GitRepoDetector — classify paths as repo/worktree/neither"
```

---

### Task 6: Git Worktree Discovery

Parse `git worktree list --porcelain` output and build `WorktreeEntry` objects.

**Files:**
- Create: `Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift`
- Create: `Tests/GrafttyKitTests/Git/GitWorktreeDiscoveryTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/GrafttyKitTests/Git/GitWorktreeDiscoveryTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitWorktreeDiscovery Tests")
struct GitWorktreeDiscoveryTests {

    @Test func parsePorcelainOutput() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        branch refs/heads/main

        worktree /Users/ben/worktrees/myapp/feature-auth
        HEAD def4567890abcdef1234567890abcdef12345678
        branch refs/heads/feature/auth

        worktree /Users/ben/worktrees/myapp/fix-bug
        HEAD 789abcdef1234567890abcdef1234567890abcdef
        branch refs/heads/fix/bug-123

        """

        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 3)
        #expect(entries[0].path == "/Users/ben/projects/myapp")
        #expect(entries[0].branch == "main")
        #expect(entries[1].path == "/Users/ben/worktrees/myapp/feature-auth")
        #expect(entries[1].branch == "feature/auth")
        #expect(entries[2].branch == "fix/bug-123")
    }

    @Test func parsesDetachedHead() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        detached

        """

        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 1)
        #expect(entries[0].branch == "(detached)")
    }

    @Test func parsesBareRepo() throws {
        let output = """
        worktree /Users/ben/projects/myapp
        HEAD abc1234567890abcdef1234567890abcdef123456
        bare

        """

        let entries = GitWorktreeDiscovery.parsePorcelain(output)
        #expect(entries.count == 1)
        #expect(entries[0].branch == "(bare)")
    }

    @Test func discoverFromRealRepo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-discover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
            git init && \
            git commit --allow-empty -m 'init' && \
            git worktree add ../wt-feature -b feature
            """]
        process.currentDirectoryURL = repoDir
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@test.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@test.com",
        ]
        try process.run()
        process.waitUntilExit()

        let entries = try GitWorktreeDiscovery.discover(repoPath: repoDir.path)
        #expect(entries.count == 2)
        #expect(entries[0].branch == "main")
        #expect(entries[1].branch == "feature")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitWorktreeDiscoveryTests 2>&1 | tail -10`
Expected: Compilation errors

- [ ] **Step 3: Implement GitWorktreeDiscovery**

`Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift`:
```swift
import Foundation

public struct DiscoveredWorktree: Sendable {
    public let path: String
    public let branch: String
}

public enum GitWorktreeDiscovery {

    /// Parse the output of `git worktree list --porcelain`.
    public static func parsePorcelain(_ output: String) -> [DiscoveredWorktree] {
        var results: [DiscoveredWorktree] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Flush previous entry
                if let path = currentPath {
                    results.append(DiscoveredWorktree(
                        path: path,
                        branch: currentBranch ?? "(unknown)"
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                currentBranch = "(detached)"
            } else if line == "bare" {
                currentBranch = "(bare)"
            }
        }

        // Flush last entry
        if let path = currentPath {
            results.append(DiscoveredWorktree(
                path: path,
                branch: currentBranch ?? "(unknown)"
            ))
        }

        return results
    }

    /// Run `git worktree list --porcelain` against a repo and return discovered worktrees.
    public static func discover(repoPath: String) throws -> [DiscoveredWorktree] {
        let output = try runGit(args: ["worktree", "list", "--porcelain"], at: repoPath)
        return parsePorcelain(output)
    }

    private static func runGit(args: [String], at directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitDiscoveryError.gitFailed(terminationStatus: process.terminationStatus)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum GitDiscoveryError: Error {
    case gitFailed(terminationStatus: Int32)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitWorktreeDiscoveryTests 2>&1 | tail -10`
Expected: All 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift Tests/GrafttyKitTests/Git/GitWorktreeDiscoveryTests.swift
git commit -m "feat: add GitWorktreeDiscovery — parse git worktree list porcelain output"
```

---

### Task 7: WorktreeMonitor (FSEvents)

Watch the filesystem for worktree additions, deletions, and branch changes.

**Files:**
- Create: `Sources/GrafttyKit/Git/WorktreeMonitor.swift`

Note: FSEvents testing is inherently timing-sensitive. This component is tested via manual integration testing rather than unit tests. The logic it delegates to (GitWorktreeDiscovery, path existence checks) is already unit-tested.

- [ ] **Step 1: Implement WorktreeMonitor**

`Sources/GrafttyKit/Git/WorktreeMonitor.swift`:
```swift
import Foundation

public protocol WorktreeMonitorDelegate: AnyObject {
    func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String)
    func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String)
    func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String)
}

public final class WorktreeMonitor: @unchecked Sendable {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "com.graftty.worktree-monitor")
    public weak var delegate: WorktreeMonitorDelegate?

    public init() {}

    deinit {
        stopAll()
    }

    /// Start watching a repo's `.git/worktrees/` directory for add/remove events.
    public func watchWorktreeDirectory(repoPath: String) {
        let gitWorktreesDir = gitWorktreesPath(for: repoPath)

        // Create the directory if it doesn't exist (repos with no worktrees won't have it)
        try? FileManager.default.createDirectory(
            atPath: gitWorktreesDir,
            withIntermediateDirectories: true
        )

        let key = "worktrees:\(repoPath)"
        guard sources[key] == nil else { return }

        guard let source = createFileWatcher(path: gitWorktreesDir, events: [.write, .link]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.worktreeMonitorDidDetectChange(self, repoPath: repoPath)
        }
        source.setCancelHandler {}
        source.resume()
        sources[key] = source
    }

    /// Watch a worktree's directory for deletion.
    public func watchWorktreePath(_ worktreePath: String) {
        let key = "path:\(worktreePath)"
        guard sources[key] == nil else { return }

        guard let source = createFileWatcher(path: worktreePath, events: [.delete, .rename]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: worktreePath) {
                self.delegate?.worktreeMonitorDidDetectDeletion(self, worktreePath: worktreePath)
            }
        }
        source.setCancelHandler {}
        source.resume()
        sources[key] = source
    }

    /// Watch a worktree's HEAD ref for branch changes.
    public func watchHeadRef(worktreePath: String, repoPath: String) {
        let headPath = resolveHeadPath(worktreePath: worktreePath, repoPath: repoPath)
        let key = "head:\(worktreePath)"
        guard sources[key] == nil else { return }

        guard let source = createFileWatcher(path: headPath, events: [.write]) else { return }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.worktreeMonitorDidDetectBranchChange(self, worktreePath: worktreePath)
        }
        source.setCancelHandler {}
        source.resume()
        sources[key] = source
    }

    /// Stop watching everything related to a specific repo.
    public func stopWatching(repoPath: String) {
        let keysToRemove = sources.keys.filter { $0.contains(repoPath) }
        for key in keysToRemove {
            sources[key]?.cancel()
            sources.removeValue(forKey: key)
        }
    }

    /// Stop all watchers.
    public func stopAll() {
        for source in sources.values {
            source.cancel()
        }
        sources.removeAll()
    }

    // MARK: - Private

    private func createFileWatcher(
        path: String,
        events: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: events,
            queue: queue
        )
        source.setCancelHandler { close(fd) }
        return source
    }

    private func gitWorktreesPath(for repoPath: String) -> String {
        "\(repoPath)/.git/worktrees"
    }

    private func resolveHeadPath(worktreePath: String, repoPath: String) -> String {
        if worktreePath == repoPath {
            // Main working tree
            return "\(repoPath)/.git/HEAD"
        }
        // Linked worktree — find its name in .git/worktrees/
        // The worktree's .git file contains: "gitdir: <repo>/.git/worktrees/<name>"
        let gitFilePath = "\(worktreePath)/.git"
        if let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8),
           contents.hasPrefix("gitdir: ") {
            let gitDir = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                .dropFirst("gitdir: ".count)
            return "\(gitDir)/HEAD"
        }
        // Fallback: try to derive the name from the path
        let name = URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(repoPath)/.git/worktrees/\(name)/HEAD"
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Git/WorktreeMonitor.swift
git commit -m "feat: add WorktreeMonitor — FSEvents watchers for worktree changes"
```

---

### Task 8: Notification Protocol & Socket Server

Build the JSON message types and Unix domain socket server for the attention notification system.

**Files:**
- Create: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Create: `Sources/GrafttyKit/Notification/SocketServer.swift`
- Create: `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`
- Create: `Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift`

- [ ] **Step 1: Write failing tests for message types**

`Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("NotificationMessage Tests")
struct NotificationMessageTests {

    @Test func encodeNotify() throws {
        let msg = NotificationMessage.notify(path: "/tmp/wt", text: "Build failed")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "notify")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["text"] as? String == "Build failed")
        #expect(json["clearAfter"] == nil)
    }

    @Test func encodeNotifyWithClearAfter() throws {
        let msg = NotificationMessage.notify(path: "/tmp/wt", text: "Done", clearAfter: 10)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["clearAfter"] as? Int == 10)
    }

    @Test func encodeClear() throws {
        let msg = NotificationMessage.clear(path: "/tmp/wt")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "clear")
        #expect(json["path"] as? String == "/tmp/wt")
    }

    @Test func decodeNotify() throws {
        let json = #"{"type": "notify", "path": "/tmp/wt", "text": "Build failed"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .notify(let path, let text, let clearAfter) = msg {
            #expect(path == "/tmp/wt")
            #expect(text == "Build failed")
            #expect(clearAfter == nil)
        } else {
            Issue.record("Expected .notify")
        }
    }

    @Test func decodeClear() throws {
        let json = #"{"type": "clear", "path": "/tmp/wt"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .clear(let path) = msg {
            #expect(path == "/tmp/wt")
        } else {
            Issue.record("Expected .clear")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationMessageTests 2>&1 | tail -10`
Expected: Compilation errors

- [ ] **Step 3: Implement NotificationMessage**

`Sources/GrafttyKit/Notification/NotificationMessage.swift`:
```swift
import Foundation

public enum NotificationMessage: Sendable {
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil)
    case clear(path: String)
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, path, text, clearAfter
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notify(let path, let text, let clearAfter):
            try container.encode("notify", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(clearAfter, forKey: .clearAfter)
        case .clear(let path):
            try container.encode("clear", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "notify":
            let path = try container.decode(String.self, forKey: .path)
            let text = try container.decode(String.self, forKey: .text)
            let clearAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .clearAfter)
            self = .notify(path: path, text: text, clearAfter: clearAfter)
        case "clear":
            let path = try container.decode(String.self, forKey: .path)
            self = .clear(path: path)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.type],
                debugDescription: "Unknown message type: \(type)"
            ))
        }
    }
}
```

- [ ] **Step 4: Run message tests to verify they pass**

Run: `swift test --filter NotificationMessageTests 2>&1 | tail -10`
Expected: All 5 tests pass

- [ ] **Step 5: Write socket integration test**

`Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift`:
```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("Socket Integration Tests")
struct SocketIntegrationTests {

    @Test func serverReceivesMessage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-sock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("test.sock").path
        let received = MutableBox<NotificationMessage?>(nil)

        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { msg in
            received.value = msg
        }
        try server.start()

        // Give server a moment to bind
        try await Task.sleep(for: .milliseconds(100))

        // Connect as client and send a message
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let bound = pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strlcpy(dest, ptr, 104)
                }
                _ = bound
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connectResult == 0)

        let msg = #"{"type":"notify","path":"/tmp/wt","text":"test"}"# + "\n"
        msg.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        close(fd)

        // Give server time to process
        try await Task.sleep(for: .milliseconds(200))

        server.stop()

        #expect(received.value != nil)
        if case .notify(let path, let text, _) = received.value {
            #expect(path == "/tmp/wt")
            #expect(text == "test")
        } else {
            Issue.record("Expected .notify message")
        }
    }
}

/// Thread-safe mutable box for test assertions.
final class MutableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
```

- [ ] **Step 6: Implement SocketServer**

`Sources/GrafttyKit/Notification/SocketServer.swift`:
```swift
import Foundation

public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.graftty.socket-server")

    public var onMessage: ((NotificationMessage) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        // Remove stale socket file
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SocketServerError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strlcpy(dest, ptr, 104)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFD)
            throw SocketServerError.bindFailed(errno: errno)
        }

        guard Darwin.listen(listenFD, 5) == 0 else {
            close(listenFD)
            throw SocketServerError.listenFailed(errno: errno)
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
            }
        }
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func acceptConnection() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        queue.async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = Darwin.read(fd, &chunk, chunkSize)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
        }

        // Parse newline-delimited JSON messages
        let lines = String(data: buffer, encoding: .utf8)?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(NotificationMessage.self, from: data) else {
                continue
            }
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(message)
            }
        }
    }
}

public enum SocketServerError: Error {
    case socketCreationFailed
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
}
```

- [ ] **Step 7: Run all notification tests**

Run: `swift test --filter "NotificationMessageTests|SocketIntegrationTests" 2>&1 | tail -10`
Expected: All 6 tests pass

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Notification/ Tests/GrafttyKitTests/Notification/
git commit -m "feat: add notification protocol and Unix domain socket server"
```

---

### Task 9: CLI Tool

Build the `graftty` CLI binary with `notify` subcommand, worktree resolution, and socket client.

**Files:**
- Create: `Sources/GrafttyCLI/WorktreeResolver.swift`
- Create: `Sources/GrafttyCLI/SocketClient.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift`

- [ ] **Step 1: Implement WorktreeResolver**

`Sources/GrafttyCLI/WorktreeResolver.swift`:
```swift
import Foundation
import GrafttyKit

enum WorktreeResolver {
    /// Resolve the current working directory to a worktree path.
    /// Walks up from PWD looking for .git file (linked worktree) or .git directory (repo root).
    static func resolve() throws -> String {
        let pwd = FileManager.default.currentDirectoryPath
        let result = try GitRepoDetector.detect(path: pwd)
        switch result {
        case .repoRoot(let path):
            return path
        case .worktree(let worktreePath, _):
            return worktreePath
        case .notARepo:
            throw CLIError.notInsideWorktree
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notInsideWorktree
    case appNotRunning
    case socketTimeout
    case socketError(String)

    var description: String {
        switch self {
        case .notInsideWorktree:
            return "Not inside a tracked worktree"
        case .appNotRunning:
            return "Graftty is not running"
        case .socketTimeout:
            return "Connection timed out after 2 seconds"
        case .socketError(let msg):
            return "Socket error: \(msg)"
        }
    }
}
```

- [ ] **Step 2: Implement SocketClient**

`Sources/GrafttyCLI/SocketClient.swift`:
```swift
import Foundation
import GrafttyKit

enum SocketClient {
    /// Send a notification message to the Graftty app via Unix domain socket.
    static func send(_ message: NotificationMessage) throws {
        let socketPath = resolveSocketPath()

        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw CLIError.appNotRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.socketError("Failed to create socket")
        }
        defer { close(fd) }

        // Set 2-second timeout
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strlcpy(dest, ptr, 104)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT {
                throw CLIError.appNotRunning
            }
            throw CLIError.socketTimeout
        }

        let data = try JSONEncoder().encode(message)
        let jsonLine = String(data: data, encoding: .utf8)! + "\n"
        jsonLine.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    private static func resolveSocketPath() -> String {
        if let envPath = ProcessInfo.processInfo.environment["GRAFTTY_SOCK"] {
            return envPath
        }
        return AppState.defaultDirectory.appendingPathComponent("graftty.sock").path
    }
}
```

- [ ] **Step 3: Implement CLI with notify subcommand**

`Sources/GrafttyCLI/CLI.swift`:
```swift
import ArgumentParser
import Foundation
import GrafttyKit

@main
struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI",
        subcommands: [Notify.self]
    )
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send an attention notification to Graftty"
    )

    @Argument(help: "Notification text to display in the sidebar")
    var text: String?

    @Flag(name: .long, help: "Clear the attention notification")
    var clear: Bool = false

    @Option(name: .long, help: "Auto-clear the notification after N seconds")
    var clearAfter: Int?

    func validate() throws {
        if !clear && text == nil {
            throw ValidationError("Provide notification text or use --clear")
        }
    }

    func run() throws {
        let worktreePath: String
        do {
            worktreePath = try WorktreeResolver.resolve()
        } catch {
            printError("Not inside a tracked worktree")
            throw ExitCode(1)
        }

        let message: NotificationMessage
        if clear {
            message = .clear(path: worktreePath)
        } else {
            message = .notify(
                path: worktreePath,
                text: text!,
                clearAfter: clearAfter.map { TimeInterval($0) }
            )
        }

        do {
            try SocketClient.send(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        }
    }

    private func printError(_ msg: String) {
        FileHandle.standardError.write(Data("graftty: \(msg)\n".utf8))
    }
}
```

- [ ] **Step 4: Verify CLI builds**

Run: `swift build --product graftty 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 5: Verify CLI shows help**

Run: `swift run graftty --help 2>&1`
Expected: Shows usage with `notify` subcommand listed

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyCLI/
git commit -m "feat: add graftty CLI with notify subcommand and socket client"
```

---

### Task 10: libghostty Bridge

Create Swift wrappers around the core libghostty C types. These adapt Ghostty's own wrapper patterns for Graftty's architecture.

**Reference files from Ghostty repo:**
- `macos/Sources/Ghostty/Ghostty.App.swift`
- `macos/Sources/Ghostty/Ghostty.Config.swift`
- `macos/Sources/Ghostty/Ghostty.Surface.swift`

**Files:**
- Create: `Sources/Graftty/Terminal/GhosttyBridge.swift`

Note: The exact API surface depends on the version of libghostty-spm. The code below follows the patterns from Ghostty's macOS frontend. If the C header (`ghostty.h`) has changed, adapt the function names accordingly. Run `swift build` after each section to catch mismatches early.

- [ ] **Step 1: Implement GhosttyBridge**

`Sources/Graftty/Terminal/GhosttyBridge.swift`:
```swift
import Foundation
import GhosttyKit

/// Swift wrapper around `ghostty_config_t`.
final class GhosttyConfig {
    let config: ghostty_config_t

    init() {
        config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
    }

    deinit {
        ghostty_config_free(config)
    }
}

/// Swift wrapper around `ghostty_app_t`.
/// There is exactly one GhosttyApp instance per Graftty process.
final class GhosttyApp {
    let app: ghostty_app_t
    private let config: GhosttyConfig

    /// Callback context stored here to prevent deallocation.
    private var runtimeConfig: ghostty_runtime_config_s

    init(config: GhosttyConfig, actionHandler: @escaping (ghostty_action_s) -> Void) {
        self.config = config

        // Store the action handler as a pointer we can retrieve in the C callback
        let handlerBox = ActionHandlerBox(handler: actionHandler)
        let handlerPtr = Unmanaged.passRetained(handlerBox).toOpaque()

        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = handlerPtr
        rtConfig.supports_selection_clipboard = false

        // Wakeup callback: dispatch tick to main thread
        rtConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                // The app instance will call tick()
                NotificationCenter.default.post(name: .ghosttyWakeup, object: nil)
            }
        }

        // Action callback: forward to Swift handler
        rtConfig.action_cb = { userdata, action in
            guard let userdata, let action else { return }
            let box = Unmanaged<ActionHandlerBox>.fromOpaque(userdata).takeUnretainedValue()
            box.handler(action.pointee)
        }

        self.runtimeConfig = rtConfig
        self.app = ghostty_app_new(&self.runtimeConfig, config.config)
    }

    deinit {
        if let ptr = runtimeConfig.userdata {
            Unmanaged<ActionHandlerBox>.fromOpaque(ptr).release()
        }
        ghostty_app_free(app)
    }

    func tick() {
        ghostty_app_tick(app)
    }
}

/// Box to pass a Swift closure through a C void* userdata pointer.
private final class ActionHandlerBox {
    let handler: (ghostty_action_s) -> Void
    init(handler: @escaping (ghostty_action_s) -> Void) {
        self.handler = handler
    }
}

extension Notification.Name {
    static let ghosttyWakeup = Notification.Name("com.graftty.ghostty.wakeup")
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds. If there are API mismatches with the libghostty-spm version, adjust the function signatures to match the installed `ghostty.h` header.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Terminal/GhosttyBridge.swift
git commit -m "feat: add GhosttyConfig and GhosttyApp — Swift wrappers for libghostty C types"
```

---

### Task 11: SurfaceHandle & TerminalManager

Create the surface wrapper and the central terminal lifecycle manager.

**Reference files from Ghostty repo:**
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- `macos/Sources/Ghostty/Ghostty.Surface.swift`

**Files:**
- Create: `Sources/Graftty/Terminal/SurfaceHandle.swift`
- Create: `Sources/Graftty/Terminal/TerminalManager.swift`

- [ ] **Step 1: Implement SurfaceHandle**

`Sources/Graftty/Terminal/SurfaceHandle.swift`:
```swift
import AppKit
import GhosttyKit
import GrafttyKit

/// Wraps a single `ghostty_surface_t` and its backing `NSView`.
/// Created when a worktree transitions to running; destroyed when stopped.
final class SurfaceHandle {
    let terminalID: TerminalID
    let surface: ghostty_surface_t
    let view: NSView
    let worktreePath: String

    init(
        terminalID: TerminalID,
        app: ghostty_app_t,
        worktreePath: String,
        socketPath: String
    ) {
        self.terminalID = terminalID
        self.worktreePath = worktreePath

        // Create the backing NSView
        let surfaceView = SurfaceNSView()
        self.view = surfaceView

        // Configure the surface
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS

        // Set the NSView pointer
        let viewPtr = Unmanaged.passUnretained(surfaceView).toOpaque()
        config.platform.macos.nsview = viewPtr

        // Set userdata to self for callbacks
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Set working directory
        config.working_directory = worktreePath.withCString { strdup($0) }

        // Set GRAFTTY_SOCK environment variable
        var envVars: [ghostty_env_var_s] = []
        let sockKey = strdup("GRAFTTY_SOCK")!
        let sockVal = strdup(socketPath)!
        envVars.append(ghostty_env_var_s(key: sockKey, value: sockVal))
        config.env_vars = UnsafeMutablePointer(mutating: envVars)
        config.env_var_count = envVars.count

        config.context = GHOSTTY_SURFACE_WINDOW
        config.scale_factor = NSScreen.main?.backingScaleFactor ?? 2.0

        self.surface = ghostty_surface_new(app, &config)

        // Clean up strdup'd strings
        free(UnsafeMutablePointer(mutating: config.working_directory))
        free(sockKey)
        free(sockVal)
    }

    deinit {
        ghostty_surface_free(surface)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    func setSize(width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    var needsConfirmQuit: Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    func requestClose() {
        ghostty_surface_request_close(surface)
    }
}

/// Minimal NSView subclass that hosts the ghostty Metal layer.
/// Ghostty attaches a CAMetalLayer to whatever NSView you provide.
class SurfaceNSView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
```

- [ ] **Step 2: Implement TerminalManager**

`Sources/Graftty/Terminal/TerminalManager.swift`:
```swift
import AppKit
import GhosttyKit
import GrafttyKit

/// Manages the lifecycle of all terminal surfaces.
/// Owns the single GhosttyApp and maps TerminalID → SurfaceHandle.
@MainActor
final class TerminalManager: ObservableObject {
    private var ghosttyApp: GhosttyApp?
    private var ghosttyConfig: GhosttyConfig?
    private var surfaces: [TerminalID: SurfaceHandle] = [:]
    private var wakeupObserver: Any?

    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Initialize libghostty. Call once at app startup.
    func initialize() {
        let config = GhosttyConfig()
        self.ghosttyConfig = config

        let app = GhosttyApp(config: config) { [weak self] action in
            DispatchQueue.main.async {
                self?.handleAction(action)
            }
        }
        self.ghosttyApp = app

        // Listen for wakeup notifications to tick the app
        wakeupObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyWakeup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ghosttyApp?.tick()
        }
    }

    /// Create surfaces for all leaves in a split tree.
    func createSurfaces(
        for splitTree: SplitTree,
        worktreePath: String
    ) -> [TerminalID: SurfaceHandle] {
        guard let app = ghosttyApp?.app else { return [:] }

        var created: [TerminalID: SurfaceHandle] = [:]
        for terminalID in splitTree.allLeaves {
            if surfaces[terminalID] == nil {
                let handle = SurfaceHandle(
                    terminalID: terminalID,
                    app: app,
                    worktreePath: worktreePath,
                    socketPath: socketPath
                )
                surfaces[terminalID] = handle
                created[terminalID] = handle
            }
        }
        return created
    }

    /// Create a single new surface (for splits).
    func createSurface(
        terminalID: TerminalID,
        worktreePath: String
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        guard surfaces[terminalID] == nil else { return surfaces[terminalID] }

        let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath
        )
        surfaces[terminalID] = handle
        return handle
    }

    /// Get the NSView for a terminal ID, if it exists.
    func view(for terminalID: TerminalID) -> NSView? {
        surfaces[terminalID]?.view
    }

    /// Set focus on a specific terminal.
    func setFocus(_ terminalID: TerminalID) {
        for (id, handle) in surfaces {
            handle.setFocus(id == terminalID)
        }
    }

    /// Check if any surface in the given set needs confirm-quit.
    func needsConfirmQuit(terminalIDs: [TerminalID]) -> Bool {
        terminalIDs.contains { surfaces[$0]?.needsConfirmQuit == true }
    }

    /// Destroy surfaces for the given terminal IDs.
    func destroySurfaces(terminalIDs: [TerminalID]) {
        for id in terminalIDs {
            surfaces[id]?.requestClose()
            surfaces.removeValue(forKey: id)
        }
    }

    /// Destroy a single surface.
    func destroySurface(terminalID: TerminalID) {
        surfaces[terminalID]?.requestClose()
        surfaces.removeValue(forKey: terminalID)
    }

    private func handleAction(_ action: ghostty_action_s) {
        // Handle libghostty actions (split requests, title changes, etc.)
        // These will be wired to AppState mutations as we build the UI.
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift Sources/Graftty/Terminal/TerminalManager.swift
git commit -m "feat: add SurfaceHandle and TerminalManager — libghostty surface lifecycle"
```

---

### Task 12: Terminal UI — SplitContainerView, SurfaceViewWrapper, TerminalContentView

Build the SwiftUI views that render the split terminal layout.

**Reference files from Ghostty repo:**
- `macos/Sources/Features/Splits/SplitView.swift`
- `macos/Sources/Features/Splits/TerminalSplitTreeView.swift`

**Files:**
- Create: `Sources/Graftty/Views/SurfaceViewWrapper.swift`
- Create: `Sources/Graftty/Views/SplitContainerView.swift`
- Create: `Sources/Graftty/Views/TerminalContentView.swift`

- [ ] **Step 1: Implement SurfaceViewWrapper**

`Sources/Graftty/Views/SurfaceViewWrapper.swift`:
```swift
import SwiftUI
import AppKit

/// Wraps a libghostty surface's NSView for use in SwiftUI.
struct SurfaceViewWrapper: NSViewRepresentable {
    let nsView: NSView

    func makeNSView(context: Context) -> NSView {
        nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed — the view is managed by libghostty
    }
}
```

- [ ] **Step 2: Implement SplitContainerView**

`Sources/Graftty/Views/SplitContainerView.swift`:
```swift
import SwiftUI
import GrafttyKit

/// A view that renders two children with a draggable divider.
/// Adapted from Ghostty's SplitView.
struct SplitContainerView<Left: View, Right: View>: View {
    let direction: SplitDirection
    @Binding var ratio: Double
    let left: Left
    let right: Right

    private let dividerThickness: CGFloat = 4
    private let minRatio: Double = 0.1
    private let maxRatio: Double = 0.9

    var body: some View {
        GeometryReader { geo in
            if direction == .horizontal {
                HStack(spacing: 0) {
                    left.frame(width: geo.size.width * ratio - dividerThickness / 2)
                    divider(isHorizontal: true, size: geo.size)
                    right.frame(width: geo.size.width * (1 - ratio) - dividerThickness / 2)
                }
            } else {
                VStack(spacing: 0) {
                    left.frame(height: geo.size.height * ratio - dividerThickness / 2)
                    divider(isHorizontal: false, size: geo.size)
                    right.frame(height: geo.size.height * (1 - ratio) - dividerThickness / 2)
                }
            }
        }
    }

    private func divider(isHorizontal: Bool, size: CGSize) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: isHorizontal ? dividerThickness : nil,
                height: isHorizontal ? nil : dividerThickness
            )
            .cursor(isHorizontal ? .resizeLeftRight : .resizeUpDown)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let total = isHorizontal ? size.width : size.height
                        let position = isHorizontal ? value.location.x : value.location.y
                        let newRatio = Double(position / total)
                        ratio = min(maxRatio, max(minRatio, newRatio))
                    }
            )
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
```

- [ ] **Step 3: Implement TerminalContentView**

`Sources/Graftty/Views/TerminalContentView.swift`:
```swift
import SwiftUI
import GrafttyKit

/// Recursively renders a SplitTree into terminal surface views.
struct TerminalContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    let splitTree: Binding<SplitTree>
    let onFocusTerminal: (TerminalID) -> Void

    var body: some View {
        if let root = splitTree.wrappedValue.root {
            nodeView(root)
        } else {
            Text("No terminal")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func nodeView(_ node: SplitTree.Node) -> some View {
        switch node {
        case .leaf(let terminalID):
            leafView(terminalID)

        case .split(let split):
            splitView(split)
        }
    }

    @ViewBuilder
    private func leafView(_ terminalID: TerminalID) -> some View {
        if let nsView = terminalManager.view(for: terminalID) {
            SurfaceViewWrapper(nsView: nsView)
                .onTapGesture {
                    onFocusTerminal(terminalID)
                }
        } else {
            Color.black
                .overlay(
                    ProgressView()
                        .controlSize(.small)
                )
        }
    }

    private func splitView(_ split: SplitTree.Node.Split) -> some View {
        // We need a binding to the ratio for dragging.
        // For now, use a local state initialized from the split's ratio.
        // In the full integration, this would update the SplitTree in AppState.
        SplitRatioContainer(
            direction: split.direction,
            initialRatio: split.ratio,
            left: { nodeView(split.left) },
            right: { nodeView(split.right) },
            onRatioChange: { _ in
                // Will be wired to AppState.updateRatio in integration
            }
        )
    }
}

/// Helper to give SplitContainerView a @State for the ratio binding.
private struct SplitRatioContainer<Left: View, Right: View>: View {
    let direction: SplitDirection
    @State var ratio: Double
    let left: () -> Left
    let right: () -> Right
    let onRatioChange: (Double) -> Void

    init(
        direction: SplitDirection,
        initialRatio: Double,
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder right: @escaping () -> Right,
        onRatioChange: @escaping (Double) -> Void
    ) {
        self.direction = direction
        self._ratio = State(initialValue: initialRatio)
        self.left = left
        self.right = right
        self.onRatioChange = onRatioChange
    }

    var body: some View {
        SplitContainerView(
            direction: direction,
            ratio: $ratio,
            left: left(),
            right: right()
        )
        .onChange(of: ratio) { _, newValue in
            onRatioChange(newValue)
        }
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/SurfaceViewWrapper.swift Sources/Graftty/Views/SplitContainerView.swift Sources/Graftty/Views/TerminalContentView.swift
git commit -m "feat: add terminal content views — SplitContainerView and recursive tree renderer"
```

---

### Task 13: Sidebar & Main Window

Build the sidebar tree view and the main window layout.

**Files:**
- Create: `Sources/Graftty/Views/WorktreeRow.swift`
- Create: `Sources/Graftty/Views/SidebarView.swift`
- Create: `Sources/Graftty/Views/BreadcrumbBar.swift`
- Create: `Sources/Graftty/Views/MainWindow.swift`

- [ ] **Step 1: Implement WorktreeRow**

`Sources/Graftty/Views/WorktreeRow.swift`:
```swift
import SwiftUI
import GrafttyKit

struct WorktreeRow: View {
    let entry: WorktreeEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            branchLabel
            Spacer()
            attentionBadge
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch entry.state {
        case .closed:
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 8, height: 8)
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        if entry.state == .stale {
            Text(entry.branch)
                .strikethrough()
                .foregroundColor(.secondary)
        } else {
            Text(entry.branch)
                .foregroundColor(isSelected ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var attentionBadge: some View {
        if let attention = entry.attention {
            Text(attention.text)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }
}
```

- [ ] **Step 2: Implement SidebarView**

`Sources/Graftty/Views/SidebarView.swift`:
```swift
import SwiftUI
import GrafttyKit

struct SidebarView: View {
    @Binding var appState: AppState
    let onSelect: (String) -> Void
    let onAddRepo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(appState.repos) { repo in
                    repoSection(repo)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(action: onAddRepo) {
                Label("Add Repository", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private func repoSection(_ repo: RepoEntry) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !repo.isCollapsed },
                set: { expanded in
                    if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[idx].isCollapsed = !expanded
                    }
                }
            )
        ) {
            ForEach(repo.worktrees) { worktree in
                WorktreeRow(
                    entry: worktree,
                    isSelected: appState.selectedWorktreePath == worktree.path
                )
                .onTapGesture {
                    onSelect(worktree.path)
                }
                .contextMenu {
                    worktreeContextMenu(worktree, repo: repo)
                }
            }
        } label: {
            Label(repo.displayName, systemImage: "folder.fill")
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private func worktreeContextMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> some View {
        if worktree.state == .running {
            Button("Stop") {
                stopWorktree(worktree, in: repo)
            }
        }
        if worktree.state == .stale {
            Button("Dismiss") {
                dismissWorktree(worktree, in: repo)
            }
        }
    }

    private func stopWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        guard let repoIdx = appState.repos.firstIndex(where: { $0.id == repo.id }),
              let wtIdx = appState.repos[repoIdx].worktrees.firstIndex(where: { $0.id == worktree.id }) else { return }
        appState.repos[repoIdx].worktrees[wtIdx].state = .closed
    }

    private func dismissWorktree(_ worktree: WorktreeEntry, in repo: RepoEntry) {
        guard let repoIdx = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
        appState.repos[repoIdx].worktrees.removeAll { $0.id == worktree.id }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    onSelect(url.path) // The app coordinator will handle detection
                }
            }
        }
        return true
    }
}
```

- [ ] **Step 3: Implement BreadcrumbBar**

`Sources/Graftty/Views/BreadcrumbBar.swift`:
```swift
import SwiftUI
import GrafttyKit

struct BreadcrumbBar: View {
    let repoName: String?
    let branchName: String?
    let path: String?

    var body: some View {
        HStack(spacing: 4) {
            if let repoName {
                Text(repoName)
                    .foregroundColor(.secondary)
            }
            if branchName != nil {
                Text("/")
                    .foregroundColor(.quaternary)
            }
            if let branchName {
                Text(branchName)
                    .foregroundColor(.accentColor)
            }
            Spacer()
            if let path {
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
```

- [ ] **Step 4: Implement MainWindow**

`Sources/Graftty/Views/MainWindow.swift`:
```swift
import SwiftUI
import GrafttyKit

struct MainWindow: View {
    @Binding var appState: AppState
    @ObservedObject var terminalManager: TerminalManager

    var body: some View {
        NavigationSplitView(
            columnVisibility: .constant(.all)
        ) {
            SidebarView(
                appState: $appState,
                onSelect: selectWorktree,
                onAddRepo: addRepository
            )
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: appState.sidebarWidth,
                max: 400
            )
        } detail: {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    repoName: selectedRepo?.displayName,
                    branchName: selectedWorktree?.branch,
                    path: selectedWorktree?.path
                )

                if let worktree = selectedWorktreeBinding {
                    TerminalContentView(
                        terminalManager: terminalManager,
                        splitTree: Binding(
                            get: { worktree.wrappedValue.splitTree },
                            set: { worktree.wrappedValue.splitTree = $0 }
                        ),
                        onFocusTerminal: { terminalID in
                            terminalManager.setFocus(terminalID)
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "No Worktree Selected",
                        systemImage: "terminal",
                        description: Text("Select a worktree from the sidebar or add a repository.")
                    )
                }
            }
        }
    }

    // MARK: - Computed properties

    private var selectedRepo: RepoEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.repo(forWorktreePath: path)
    }

    private var selectedWorktree: WorktreeEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.worktree(forPath: path)
    }

    private var selectedWorktreeBinding: Binding<WorktreeEntry>? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    return $appState.repos[repoIdx].worktrees[wtIdx]
                }
            }
        }
        return nil
    }

    // MARK: - Actions

    private func selectWorktree(_ path: String) {
        appState.selectedWorktreePath = path

        // If the worktree is closed, start it
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path
                    && appState.repos[repoIdx].worktrees[wtIdx].state == .closed {

                    // Create default split tree if none exists
                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    // Create surfaces
                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    _ = terminalManager.createSurfaces(for: splitTree, worktreePath: path)

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
                }
            }
        }

        // Clear attention on focus
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    appState.repos[repoIdx].worktrees[wtIdx].attention = nil
                }
            }
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository or worktree directory"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addPath(url.path)
    }

    private func addPath(_ path: String) {
        guard let detection = try? GitRepoDetector.detect(path: path) else { return }

        switch detection {
        case .repoRoot(let repoPath):
            addRepoFromPath(repoPath, selectWorktree: nil)
        case .worktree(let worktreePath, let repoPath):
            addRepoFromPath(repoPath, selectWorktree: worktreePath)
        case .notARepo:
            let alert = NSAlert()
            alert.messageText = "Not a Git Repository"
            alert.informativeText = "\(path) is not a git repository or worktree."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func addRepoFromPath(_ repoPath: String, selectWorktree: String?) {
        guard !appState.repos.contains(where: { $0.path == repoPath }) else {
            // Already exists, just select
            if let wt = selectWorktree {
                appState.selectedWorktreePath = wt
            }
            return
        }

        guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }

        let worktrees = discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }
        let displayName = URL(fileURLWithPath: repoPath).lastPathComponent
        let repo = RepoEntry(path: repoPath, displayName: displayName, worktrees: worktrees)
        appState.addRepo(repo)

        if let wt = selectWorktree {
            self.selectWorktree(wt)
        } else if let first = worktrees.first {
            self.selectWorktree(first.path)
        }
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/Views/
git commit -m "feat: add sidebar, breadcrumb bar, and main window layout"
```

---

### Task 14: App Entry Point & Menus

Wire everything together in the app entry point with menu commands for splitting, adding repos, and installing the CLI.

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Implement GrafttyApp**

`Sources/Graftty/GrafttyApp.swift`:
```swift
import SwiftUI
import GrafttyKit

@main
struct GrafttyApp: App {
    @State private var appState: AppState
    @StateObject private var terminalManager: TerminalManager
    private let socketServer: SocketServer
    private let worktreeMonitor = WorktreeMonitor()

    init() {
        let loaded = (try? AppState.load(from: AppState.defaultDirectory)) ?? AppState()
        _appState = State(initialValue: loaded)

        let socketPath = AppState.defaultDirectory.appendingPathComponent("graftty.sock").path
        _terminalManager = StateObject(wrappedValue: TerminalManager(socketPath: socketPath))
        socketServer = SocketServer(socketPath: socketPath)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(appState: $appState, terminalManager: terminalManager)
                .onAppear { startup() }
                .onChange(of: appState) { _, newState in
                    try? newState.save(to: AppState.defaultDirectory)
                }
        }
        .defaultSize(
            width: appState.windowFrame.width,
            height: appState.windowFrame.height
        )
        .defaultPosition(.init(
            x: appState.windowFrame.x,
            y: appState.windowFrame.y
        ))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Repository...") {
                    // Handled by MainWindow
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Split Horizontally") {
                    splitFocusedPane(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Vertically") {
                    splitFocusedPane(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("Graftty") {
                Button("Install CLI Tool...") {
                    installCLI()
                }
            }
        }
    }

    private func startup() {
        // Initialize libghostty
        terminalManager.initialize()

        // Start socket server for CLI notifications
        try? socketServer.start()
        socketServer.onMessage = { [self] message in
            handleNotification(message)
        }

        // Start worktree monitoring for all repos
        worktreeMonitor.delegate = WorktreeMonitorBridge(appState: $appState)
        for repo in appState.repos {
            worktreeMonitor.watchWorktreeDirectory(repoPath: repo.path)
            for wt in repo.worktrees {
                worktreeMonitor.watchWorktreePath(wt.path)
                worktreeMonitor.watchHeadRef(worktreePath: wt.path, repoPath: repo.path)
            }
        }

        // Reconcile saved state against current disk state
        reconcileOnLaunch()

        // Restore running worktrees
        restoreRunningWorktrees()

        // Offer CLI installation on first launch
        offerCLIInstallIfNeeded()
    }

    private func reconcileOnLaunch() {
        for repoIdx in appState.repos.indices {
            let repoPath = appState.repos[repoIdx].path
            guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
            let discoveredPaths = Set(discovered.map(\.path))

            // Add new worktrees discovered while app was closed
            let existingPaths = Set(appState.repos[repoIdx].worktrees.map(\.path))
            for d in discovered where !existingPaths.contains(d.path) {
                appState.repos[repoIdx].worktrees.append(
                    WorktreeEntry(path: d.path, branch: d.branch)
                )
            }

            // Mark removed worktrees as stale
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    appState.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }

            // Update branch names
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if let match = discovered.first(where: { $0.path == appState.repos[repoIdx].worktrees[wtIdx].path }) {
                    appState.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                }
            }
        }
    }

    private func offerCLIInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "cliInstallOffered") else { return }
        defaults.set(true, forKey: "cliInstallOffered")

        let symlinkPath = "/usr/local/bin/graftty"
        guard !FileManager.default.fileExists(atPath: symlinkPath) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            installCLI()
        }
    }

    private func restoreRunningWorktrees() {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.state == .running {
                    // Worktree was running when app quit — restart terminals
                    if wt.splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }
                    _ = terminalManager.createSurfaces(
                        for: appState.repos[repoIdx].worktrees[wtIdx].splitTree,
                        worktreePath: wt.path
                    )
                }
            }
        }
    }

    private func handleNotification(_ message: NotificationMessage) {
        switch message {
        case .notify(let path, let text, let clearAfter):
            for repoIdx in appState.repos.indices {
                for wtIdx in appState.repos[repoIdx].worktrees.indices {
                    if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.repos[repoIdx].worktrees[wtIdx].attention = Attention(
                            text: text,
                            timestamp: Date(),
                            clearAfter: clearAfter
                        )

                        // Schedule auto-clear if needed
                        if let clearAfter {
                            DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [self] in
                                for ri in appState.repos.indices {
                                    for wi in appState.repos[ri].worktrees.indices {
                                        if appState.repos[ri].worktrees[wi].path == path {
                                            appState.repos[ri].worktrees[wi].attention = nil
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .clear(let path):
            for repoIdx in appState.repos.indices {
                for wtIdx in appState.repos[repoIdx].worktrees.indices {
                    if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                        appState.repos[repoIdx].worktrees[wtIdx].attention = nil
                    }
                }
            }
        }
    }

    private func splitFocusedPane(direction: SplitDirection) {
        guard let path = appState.selectedWorktreePath else { return }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path, wt.state == .running,
                   let focused = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first {
                    let newID = TerminalID()
                    appState.repos[repoIdx].worktrees[wtIdx].splitTree =
                        wt.splitTree.inserting(newID, at: focused, direction: direction)
                    _ = terminalManager.createSurface(terminalID: newID, worktreePath: path)
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newID
                    terminalManager.setFocus(newID)
                    return
                }
            }
        }
    }

    private func installCLI() {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/graftty")
        let symlink = "/usr/local/bin/graftty"

        let alert = NSAlert()
        alert.messageText = "Install CLI Tool"
        alert.informativeText = "Create a symlink at \(symlink) pointing to the Graftty CLI?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try? FileManager.default.removeItem(atPath: symlink)
            try FileManager.default.createSymbolicLink(
                atPath: symlink,
                withDestinationPath: bundleCLI.path
            )
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Installation Failed"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }
}

/// Bridge between WorktreeMonitor (delegate protocol) and AppState (value type).
@MainActor
final class WorktreeMonitorBridge: WorktreeMonitorDelegate {
    let appState: Binding<AppState>

    init(appState: Binding<AppState>) {
        self.appState = appState
    }

    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        Task { @MainActor in
            guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
            guard let repoIdx = appState.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let existing = appState.wrappedValue.repos[repoIdx].worktrees
            let existingPaths = Set(existing.map(\.path))
            let discoveredPaths = Set(discovered.map(\.path))

            // Add new worktrees
            for d in discovered where !existingPaths.contains(d.path) {
                let entry = WorktreeEntry(path: d.path, branch: d.branch)
                appState.wrappedValue.repos[repoIdx].worktrees.append(entry)
            }

            // Mark removed worktrees as stale
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        Task { @MainActor in
            for repoIdx in appState.wrappedValue.repos.indices {
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        Task { @MainActor in
            for repoIdx in appState.wrappedValue.repos.indices {
                let repoPath = appState.wrappedValue.repos[repoIdx].path
                guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
                for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                    if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath,
                       let match = discovered.first(where: { $0.path == worktreePath }) {
                        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat: wire up app entry point with menus, socket server, monitoring, and persistence"
```

---

### Task 15: Keyboard Navigation & Stop Worktree Integration

Wire up keyboard shortcuts for pane navigation and the stop-worktree flow with confirmation.

**Files:**
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Add pane navigation commands to GrafttyApp**

In `Sources/Graftty/GrafttyApp.swift`, add to the `.commands` block inside the `CommandGroup(after: .newItem)` section:

```swift
Divider()

Button("Focus Pane Left") {
    navigatePane(.left)
}
.keyboardShortcut(.leftArrow, modifiers: [.command, .option])

Button("Focus Pane Right") {
    navigatePane(.right)
}
.keyboardShortcut(.rightArrow, modifiers: [.command, .option])

Button("Focus Pane Up") {
    navigatePane(.up)
}
.keyboardShortcut(.upArrow, modifiers: [.command, .option])

Button("Focus Pane Down") {
    navigatePane(.down)
}
.keyboardShortcut(.downArrow, modifiers: [.command, .option])

Divider()

Button("Close Pane") {
    closeFocusedPane()
}
.keyboardShortcut("w", modifiers: [.command])
```

- [ ] **Step 2: Add navigation helper methods to GrafttyApp**

Add these methods to GrafttyApp:

```swift
private func navigatePane(_ direction: NavigationDirection) {
    // Spatial navigation through the split tree.
    // This is a simplified version — Ghostty's SplitTree has a more
    // sophisticated focusTarget(for:from:) that we can port later.
    guard let path = appState.selectedWorktreePath else { return }
    for repoIdx in appState.repos.indices {
        for wtIdx in appState.repos[repoIdx].worktrees.indices {
            let wt = appState.repos[repoIdx].worktrees[wtIdx]
            if wt.path == path, wt.state == .running {
                let leaves = wt.splitTree.allLeaves
                guard leaves.count > 1,
                      let currentIdx = leaves.firstIndex(where: { $0 == wt.focusedTerminalID }) else { return }

                let nextIdx: Int
                switch direction {
                case .left, .up:
                    nextIdx = (currentIdx - 1 + leaves.count) % leaves.count
                case .right, .down:
                    nextIdx = (currentIdx + 1) % leaves.count
                }

                let nextID = leaves[nextIdx]
                appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = nextID
                terminalManager.setFocus(nextID)
                return
            }
        }
    }
}

private func closeFocusedPane() {
    guard let path = appState.selectedWorktreePath else { return }
    for repoIdx in appState.repos.indices {
        for wtIdx in appState.repos[repoIdx].worktrees.indices {
            let wt = appState.repos[repoIdx].worktrees[wtIdx]
            if wt.path == path, wt.state == .running,
               let focused = wt.focusedTerminalID {
                terminalManager.destroySurface(terminalID: focused)
                let newTree = wt.splitTree.removing(focused)
                appState.repos[repoIdx].worktrees[wtIdx].splitTree = newTree

                if newTree.root == nil {
                    appState.repos[repoIdx].worktrees[wtIdx].state = .closed
                } else {
                    let newFocus = newTree.allLeaves.first
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newFocus
                    if let newFocus { terminalManager.setFocus(newFocus) }
                }
                return
            }
        }
    }
}

enum NavigationDirection {
    case left, right, up, down
}
```

- [ ] **Step 3: Update SidebarView stop-worktree to use TerminalManager**

In `Sources/Graftty/Views/MainWindow.swift`, update `selectWorktree` to handle stop with confirmation. The `SidebarView.stopWorktree` method should post a notification that `MainWindow` handles with a confirmation dialog:

Add this method to `MainWindow`:

```swift
func stopWorktreeWithConfirmation(_ worktreePath: String) {
    for repoIdx in appState.repos.indices {
        for wtIdx in appState.repos[repoIdx].worktrees.indices {
            let wt = appState.repos[repoIdx].worktrees[wtIdx]
            if wt.path == worktreePath && wt.state == .running {
                let terminalIDs = wt.splitTree.allLeaves
                if terminalManager.needsConfirmQuit(terminalIDs: terminalIDs) {
                    let alert = NSAlert()
                    alert.messageText = "Stop Worktree?"
                    alert.informativeText = "There are running processes in \(wt.branch). Stop all terminals?"
                    alert.addButton(withTitle: "Stop")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                terminalManager.destroySurfaces(terminalIDs: terminalIDs)
                appState.repos[repoIdx].worktrees[wtIdx].state = .closed
                return
            }
        }
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build --target Graftty 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/MainWindow.swift
git commit -m "feat: add keyboard pane navigation, close pane, and stop-worktree with confirmation"
```

---

### Task 16: Integration Test & Final Verification

Run all tests, verify the app builds and launches, and ensure the full pipeline works.

**Files:** No new files — this is a verification task.

- [ ] **Step 1: Run all unit tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (SplitTree, WorktreeEntry, AppState, GitRepoDetector, GitWorktreeDiscovery, NotificationMessage, Socket)

- [ ] **Step 2: Build all targets**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds for Graftty, graftty CLI, and GrafttyKit

- [ ] **Step 3: Verify CLI help output**

Run: `swift run graftty notify --help 2>&1`
Expected: Shows notify subcommand help with `text`, `--clear`, and `--clear-after` arguments

- [ ] **Step 4: Run the app (manual verification)**

Run: `swift run Graftty`
Expected: The app window opens with an empty sidebar showing "No Worktree Selected" in the detail area. The sidebar has an "Add Repository" button. The window is resizable.

Verify:
- Add a repository via "Add Repository" button — worktrees appear in sidebar
- Click a worktree — terminal appears
- Split terminal (Cmd+D) — two panes side by side
- Close pane (Cmd+W) — returns to single pane
- Switch between worktrees — terminals persist

- [ ] **Step 5: Test notification flow (manual)**

In one terminal inside the running app:
```bash
echo '{"type":"notify","path":"<worktree-path>","text":"Build failed"}' | nc -U ~/Library/Application\ Support/Graftty/graftty.sock
```

Verify: Red "Build failed" badge appears next to the worktree in the sidebar. Clicking the worktree clears it.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore: final integration verification — all tests pass, app builds and runs"
```

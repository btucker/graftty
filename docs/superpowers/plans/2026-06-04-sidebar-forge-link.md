# Sidebar Forge Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project-level sidebar rows show a clickable GitHub/GitLab logo to the left of the project name that opens `https://<host>/<owner>/<repo>` in the browser.

**Architecture:** `PRStatusStore` (which already detects and caches each repo's `HostingOrigin`) gains an observable `originByRepo` dictionary. The app target gains a code-drawn forge-mark view (`ForgeLogoMark`) backed by a small SVG path-data parser (`SVGPathShape`) — no bundled image resources (this repo has shipped two broken releases from resource-bundling mistakes). A pure `ForgePresentation` helper maps `HostingProvider` → mark/menu-title so the behavior is testable without rendering. `SidebarView.repoSection` wires it together.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`@Suite`), SwiftPM. Spec annotations per the repo's `@spec` EARS convention (see `CLAUDE.md`).

**Design spec:** `docs/superpowers/specs/2026-06-04-sidebar-forge-link-design.md`

**New spec IDs (PROJECT-2.x cluster):**
- `PROJECT-2.0` — supported-forge logo displayed left of project name
- `PROJECT-2.1` — clicking opens `https://<host>/<owner>/<repo>`
- `PROJECT-2.2` — no icon for no-origin/unsupported repos
- `PROJECT-2.3` — context-menu "Open on GitHub…/GitLab…" item
- `PROJECT-2.4` — `PRStatusStore.originByRepo` publishes resolved origins

**File map:**
- Modify: `Sources/GrafttyKit/Hosting/HostingOrigin.swift` — add `webURL`
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift` — add `originByRepo`
- Create: `Sources/Graftty/Views/SVGPathShape.swift` — SVG path-data → SwiftUI `Shape`
- Create: `Sources/Graftty/Views/ForgeLogoMark.swift` — marks + `ForgePresentation`
- Modify: `Sources/Graftty/Views/SidebarView.swift` — repo-row button + context menu
- Test: `Tests/GrafttyTests/Specs/ProjectTests.swift` (append PROJECT-2.x suites)
- Test: `Tests/GrafttyKitTests/PRStatus/PRStatusStoreOriginPublishTests.swift` (create)
- Test: `Tests/GrafttyTests/Views/SVGPathShapeTests.swift` (create)
- Regenerate: `SPECS.md` via `scripts/generate-specs.py`

All commands run from the repo root: `/Users/btucker/projects/graftty/.worktrees/add-github-link`.

---

### Task 1: `HostingOrigin.webURL` (PROJECT-2.1)

**Files:**
- Modify: `Sources/GrafttyKit/Hosting/HostingOrigin.swift`
- Test: `Tests/GrafttyTests/Specs/ProjectTests.swift` (append at end of file)

- [ ] **Step 1: Write the failing test**

Append to `Tests/GrafttyTests/Specs/ProjectTests.swift`:

```swift
@Suite("@spec PROJECT-2.1: When the forge logo is clicked, the application shall open https://<host>/<owner>/<repo> in the default browser.")
struct HostingOriginWebURLTests {
    @Test("github.com origin composes the canonical project URL")
    func githubDotCom() {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty")
        #expect(origin.webURL == URL(string: "https://github.com/btucker/graftty"))
    }

    @Test("Self-hosted GitLab origin uses its own host")
    func selfHostedGitLab() {
        let origin = HostingOrigin(provider: .gitlab, host: "gitlab.corp.example", owner: "team", repo: "tool")
        #expect(origin.webURL == URL(string: "https://gitlab.corp.example/team/tool"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HostingOriginWebURLTests`
Expected: compile error — `value of type 'HostingOrigin' has no member 'webURL'`

- [ ] **Step 3: Write the minimal implementation**

In `Sources/GrafttyKit/Hosting/HostingOrigin.swift`, after the `slug` property:

```swift
    /// Project home page on the forge (PROJECT-2.1). `host` comes from
    /// a parsed remote URL, so this composes for self-hosted instances
    /// (e.g. `gitlab.corp.example`) as well as github.com/gitlab.com.
    public var webURL: URL? {
        URL(string: "https://\(host)/\(owner)/\(repo)")
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter HostingOriginWebURLTests`
Expected: 2 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Hosting/HostingOrigin.swift Tests/GrafttyTests/Specs/ProjectTests.swift
git commit -m "feat(PROJECT-2.1): HostingOrigin.webURL composes the forge project URL"
```

---

### Task 2: `PRStatusStore.originByRepo` (PROJECT-2.4)

**Files:**
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Test: `Tests/GrafttyKitTests/PRStatus/PRStatusStoreOriginPublishTests.swift` (create)

Context for the implementer: `PRStatusStore` already detects each repo's origin via the injectable `detectHost` closure and caches it in the private `hostByRepo: [String: HostingOrigin?]` (nil value = known no-origin). The single write site is in `performRepoFetch` (`hostByRepo[repoPath] = detected`). Stale repos are pruned in `pruneStaleRepoState`, called from `tick()`. The store is `@MainActor @Observable`; properties NOT marked `@ObservationIgnored` are observable. Test helpers `ManualTicker` (with `fire()`) and `FakeCLIExecutor` live in `Tests/GrafttyKitTests/PRStatus/Support/`.

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/PRStatus/PRStatusStoreOriginPublishTests.swift`:

```swift
import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

@Suite("@spec PROJECT-2.4: When origin detection resolves a repo's origin remote, the application shall publish the resolved HostingOrigin in PRStatusStore.originByRepo, omit repos whose detection returns nil, and prune entries for repos removed from the model.")
struct PRStatusStoreOriginPublishTests {

    @MainActor
    private final class ReposBox {
        var repos: [RepoEntry]
        init(_ repos: [RepoEntry]) { self.repos = repos }
    }

    private static func repoEntry(path: String) -> RepoEntry {
        RepoEntry(
            path: path,
            displayName: (path as NSString).lastPathComponent,
            worktrees: [WorktreeEntry(path: "\(path)/wt", branch: "feature/x", state: .running)]
        )
    }

    /// Store with a stubbed detector and no fetcher (PR fetching is
    /// irrelevant to origin publication). Returns the store, ticker,
    /// and the mutable repo list backing getRepos.
    @MainActor
    private static func makeStore(
        detect: @Sendable @escaping (String) async throws -> HostingOrigin?,
        repos: [RepoEntry]
    ) -> (PRStatusStore, ManualTicker, ReposBox) {
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: detect
        )
        let ticker = ManualTicker()
        let box = ReposBox(repos)
        store.start(ticker: ticker, getRepos: { box.repos })
        return (store, ticker, box)
    }

    @MainActor
    private static func waitForOrigin(_ store: PRStatusStore, repoPath: String) async throws {
        for _ in 0..<50 {
            if store.originByRepo[repoPath] != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func publishesResolvedOriginAfterFetch() async throws {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)
        await MainActor.run { store.stop() }
    }

    @Test func publishesUnsupportedOriginsToo() async throws {
        // The store publishes every resolved origin; filtering
        // unsupported providers is presentation's job (PROJECT-2.2).
        let origin = HostingOrigin(provider: .unsupported, host: "bitbucket.org", owner: "foo", repo: "bar")
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)
        await MainActor.run { store.stop() }
    }

    @Test func omitsReposWithNoOrigin() async throws {
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in nil },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        // Give the detect Task time to land, then confirm nothing was published.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await store.originByRepo.isEmpty)
        await MainActor.run { store.stop() }
    }

    @Test func prunesOriginsForRemovedRepos() async throws {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let (store, ticker, box) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)

        await MainActor.run { box.repos = [] }
        await ticker.fire()
        #expect(await store.originByRepo.isEmpty)
        await MainActor.run { store.stop() }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PRStatusStoreOriginPublishTests`
Expected: compile error — `value of type 'PRStatusStore' has no member 'originByRepo'`

- [ ] **Step 3: Write the minimal implementation**

In `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`, three edits:

(a) Add the observable property after `public private(set) var prsByRepoBranch: [String: [String: PRInfo]] = [:]`:

```swift
    /// Resolved origin per repo path, published as detection completes.
    /// Unlike the private `hostByRepo` cache (whose nil values mean
    /// "known no-origin"), this only ever holds successfully parsed
    /// origins — including `.unsupported` providers, which presentation
    /// filters out. Drives the sidebar forge link. @spec PROJECT-2.4
    public private(set) var originByRepo: [String: HostingOrigin] = [:]
```

(b) In `performRepoFetch`, the existing detection branch reads:

```swift
            do {
                let detected = try await detectHost(repoPath)
                origin = detected
                hostByRepo[repoPath] = detected
            } catch {
```

Add one line so it becomes:

```swift
            do {
                let detected = try await detectHost(repoPath)
                origin = detected
                hostByRepo[repoPath] = detected
                if let detected { originByRepo[repoPath] = detected }
            } catch {
```

(c) In `pruneStaleRepoState`, add a fourth prune loop alongside the existing three:

```swift
        for repoPath in originByRepo.keys where !currentRepoPaths.contains(repoPath) {
            originByRepo.removeValue(forKey: repoPath)
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PRStatusStoreOriginPublishTests`
Expected: 4 tests PASS

- [ ] **Step 5: Run the rest of the PRStatusStore tests for regressions**

Run: `swift test --filter PRStatusStore`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift Tests/GrafttyKitTests/PRStatus/PRStatusStoreOriginPublishTests.swift
git commit -m "feat(PROJECT-2.4): PRStatusStore publishes resolved origins in originByRepo"
```

---

### Task 3: `SVGPathShape` — SVG path-data parser

**Files:**
- Create: `Sources/Graftty/Views/SVGPathShape.swift`
- Test: `Tests/GrafttyTests/Views/SVGPathShapeTests.swift` (create)

This is internal mechanism (no `@spec` — same as other view-support tests in `Tests/GrafttyTests/Views/`). It must support the exact command set used by the GitHub/GitLab marks: `M/m`, `L/l` (including implicit repetition after M/L), `H/h`, `V/v`, `C/c`, `S/s`, `A/a`, `Z/z`. Two SVG tokenizer subtleties matter for the real mark data: a `-` starts a new number (`".55-.17"` is two numbers) and a second `.` starts a new number (`"20.3.9814"` is `20.3` and `.9814`).

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyTests/Views/SVGPathShapeTests.swift`:

```swift
import Testing
import SwiftUI
@testable import Graftty

@Suite("SVGPathParser — path-data parsing")
struct SVGPathParserTests {
    private func bounds(_ d: String) -> CGRect {
        SVGPathParser.parse(d).boundingRect
    }

    @Test("Absolute move/line/close")
    func absoluteMoveLine() {
        let rect = bounds("M0 0L10 0 10 10Z")
        #expect(abs(rect.minX - 0) < 0.001)
        #expect(abs(rect.minY - 0) < 0.001)
        #expect(abs(rect.width - 10) < 0.001)
        #expect(abs(rect.height - 10) < 0.001)
    }

    @Test("Relative commands accumulate from the current point")
    func relativeCommands() {
        let rect = bounds("m1 1l2 0 0 2z")
        #expect(abs(rect.minX - 1) < 0.001)
        #expect(abs(rect.minY - 1) < 0.001)
        #expect(abs(rect.maxX - 3) < 0.001)
        #expect(abs(rect.maxY - 3) < 0.001)
    }

    @Test("Negative sign and repeated decimal point both delimit numbers")
    func numberTokenization() {
        // "20.3.9814" must parse as x=20.3, y=.9814 — the second dot
        // starts a new number. "-5-5" must parse as two numbers.
        let rect = bounds("M20.3.9814L-5-5")
        #expect(abs(rect.minX - (-5)) < 0.001)
        #expect(abs(rect.minY - (-5)) < 0.001)
        #expect(abs(rect.maxX - 20.3) < 0.001)
        #expect(abs(rect.maxY - 0.9814) < 0.001)
    }

    @Test("Horizontal, vertical, cubic, and smooth-cubic commands")
    func curvesAndAxisLines() {
        let rect = bounds("M0 0H10V10C10 15 5 15 5 10S0 5 0 10z")
        #expect(abs(rect.minX - 0) < 0.001)
        #expect(abs(rect.maxX - 10) < 0.001)
        #expect(rect.maxY > 10) // the cubics bow below y=10
    }

    @Test("Arc command produces a half-circle of the expected extent")
    func arcCommand() {
        // Semicircle of radius 5 from (0,0) to (10,0).
        let rect = bounds("M0 0A5 5 0 0 1 10 0")
        #expect(abs(rect.width - 10) < 0.01)
        #expect(abs(rect.height - 5) < 0.05)
    }

}

@Suite("SVGPathShape — viewBox scaling")
struct SVGPathShapeScalingTests {
    @Test("Path scales to the proposed rect")
    func scalesToRect() {
        let shape = SVGPathShape(pathData: "M0 0L16 0 16 16 0 16Z", viewBox: CGSize(width: 16, height: 16))
        let rect = shape.path(in: CGRect(x: 0, y: 0, width: 13, height: 13)).boundingRect
        #expect(abs(rect.width - 13) < 0.001)
        #expect(abs(rect.height - 13) < 0.001)
    }
}
```

(Geometry tests against the real GitHub/GitLab mark data are added in Task 4, which creates `ForgePresentation.Mark`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SVGPath`
Expected: compile error — `cannot find 'SVGPathParser' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Graftty/Views/SVGPathShape.swift`:

```swift
import SwiftUI

/// Renders an SVG path-data string (the `d` attribute) as a SwiftUI
/// `Shape`, uniformly scaling the declared viewBox to the proposed
/// rect. Exists so the sidebar's forge marks (ForgeLogoMark) can be
/// drawn from vendored vector data with no bundled image resources —
/// this project has shipped broken releases from resource-bundling
/// gaps, so geometry-in-code is deliberate.
struct SVGPathShape: Shape {
    let pathData: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let parsed = SVGPathParser.parse(pathData)
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
        return parsed.applying(transform)
    }
}

/// Minimal SVG path-data parser covering the command set the vendored
/// forge marks use: M/m, L/l (incl. implicit repetition), H/h, V/v,
/// C/c, S/s, A/a, Z/z. Unsupported commands abort the remainder of
/// the string, leaving whatever was parsed so far.
enum SVGPathParser {

    static func parse(_ d: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Reflected control point for S — the previous C/S command's
        /// second control point, when the previous command was a cubic.
        var lastCubicControl: CGPoint?

        let tokens = tokenize(d)
        var index = 0

        func numbers(_ count: Int) -> [CGFloat]? {
            var result: [CGFloat] = []
            while result.count < count, index < tokens.count {
                guard case .number(let value) = tokens[index] else { return nil }
                result.append(value)
                index += 1
            }
            return result.count == count ? result : nil
        }

        var command: Character = " "
        while index < tokens.count {
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            // (Otherwise: implicit repetition of the previous command.)

            let isRelative = command.isLowercase
            let origin = isRelative ? current : .zero

            switch Character(command.lowercased()) {
            case "m":
                guard let n = numbers(2) else { return path }
                current = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                path.move(to: current)
                subpathStart = current
                lastCubicControl = nil
                // Implicit subsequent pairs are linetos.
                command = isRelative ? "l" : "L"
            case "l":
                guard let n = numbers(2) else { return path }
                current = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                path.addLine(to: current)
                lastCubicControl = nil
            case "h":
                guard let n = numbers(1) else { return path }
                current = CGPoint(x: origin.x + n[0], y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "v":
                guard let n = numbers(1) else { return path }
                current = CGPoint(x: current.x, y: origin.y + n[0])
                path.addLine(to: current)
                lastCubicControl = nil
            case "c":
                guard let n = numbers(6) else { return path }
                let c1 = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                let c2 = CGPoint(x: origin.x + n[2], y: origin.y + n[3])
                current = CGPoint(x: origin.x + n[4], y: origin.y + n[5])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "s":
                guard let n = numbers(4) else { return path }
                let c1: CGPoint
                if let prev = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    c1 = current
                }
                let c2 = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                current = CGPoint(x: origin.x + n[2], y: origin.y + n[3])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "a":
                guard let n = numbers(7) else { return path }
                let end = CGPoint(x: origin.x + n[5], y: origin.y + n[6])
                appendArc(
                    to: &path, from: current,
                    rx: n[0], ry: n[1],
                    xAxisRotationDegrees: n[2],
                    largeArc: n[3] != 0, sweep: n[4] != 0,
                    end: end
                )
                current = end
                lastCubicControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
            default:
                return path
            }
        }
        return path
    }

    // MARK: - Tokenizer

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    /// SVG number tokenization: `-` begins a new number, and a second
    /// `.` within one number begins a new number (`"20.3.9814"` →
    /// 20.3, .9814). Commas and whitespace are separators.
    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            if !current.isEmpty, let value = Double(current.hasPrefix(".") ? "0" + current : current) {
                tokens.append(.number(CGFloat(value)))
            } else if current == "-" || current == "-." {
                // malformed fragment; drop it
            }
            current = ""
        }
        for ch in d {
            if ch.isLetter {
                flush()
                tokens.append(.command(ch))
            } else if ch == "," || ch.isWhitespace {
                flush()
            } else if ch == "-" {
                flush()
                current = "-"
            } else if ch == "." && current.contains(".") {
                flush()
                current = "."
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    // MARK: - Elliptical arc → cubic beziers

    /// W3C SVG implementation notes, appendix B.2.4: convert endpoint
    /// parameterization to center parameterization, then emit one
    /// cubic per <=90° arc segment.
    private static func appendArc(
        to path: inout Path, from start: CGPoint,
        rx: CGFloat, ry: CGFloat,
        xAxisRotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool,
        end: CGPoint
    ) {
        guard rx != 0, ry != 0, start != end else {
            path.addLine(to: end)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // (x1', y1')
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Correct out-of-range radii.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        // (cx', cy')
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = (largeArc != sweep ? 1.0 : -1.0) * sqrt(max(0, num / den))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        // (cx, cy)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        // Split into <=90° segments, each approximated by one cubic.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        // Control-point distance for a unit-circle arc of angle `delta`.
        let t = 4 / 3 * tan(delta / 4)

        var theta = theta1
        for _ in 0..<segments {
            let theta2 = theta + delta
            func point(_ a: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                    y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi
                )
            }
            func derivative(_ a: CGFloat) -> CGPoint {
                CGPoint(
                    x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                    y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi
                )
            }
            let p1 = point(theta), p2 = point(theta2)
            let d1 = derivative(theta), d2 = derivative(theta2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            )
            theta = theta2
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SVGPath`
Expected: 6 tests PASS (the two mark-geometry tests arrive in Task 4)

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/SVGPathShape.swift Tests/GrafttyTests/Views/SVGPathShapeTests.swift
git commit -m "feat: SVGPathShape — minimal SVG path-data parser for code-drawn marks"
```

---

### Task 4: `ForgePresentation` + `ForgeLogoMark` (PROJECT-2.0, 2.2, 2.3)

**Files:**
- Create: `Sources/Graftty/Views/ForgeLogoMark.swift`
- Test: `Tests/GrafttyTests/Specs/ProjectTests.swift` (append)
- Test: `Tests/GrafttyTests/Views/SVGPathShapeTests.swift` (append the two mark tests)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GrafttyTests/Specs/ProjectTests.swift`:

```swift
@Suite("@spec PROJECT-2.0: While a repo's origin remote resolves to a supported forge (GitHub or GitLab, including self-hosted hosts), the application shall display that forge's logo to the left of the project name in the sidebar.")
struct ForgePresentationMarkTests {
    @Test("GitHub provider maps to the GitHub mark")
    func githubMark() {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "a", repo: "b")
        #expect(ForgePresentation(origin: origin)?.mark == .github)
    }

    @Test("GitLab provider maps to the GitLab mark, self-hosted included")
    func gitlabMark() {
        let origin = HostingOrigin(provider: .gitlab, host: "gitlab.corp.example", owner: "a", repo: "b")
        #expect(ForgePresentation(origin: origin)?.mark == .gitlab)
    }
}

@Suite("@spec PROJECT-2.2: If a repo has no origin remote or the origin's provider is unsupported, then the application shall render the project row with no forge icon.")
struct ForgePresentationAbsentTests {
    @Test("Unsupported provider yields no presentation")
    func unsupportedProvider() {
        let origin = HostingOrigin(provider: .unsupported, host: "bitbucket.org", owner: "a", repo: "b")
        #expect(ForgePresentation(origin: origin) == nil)
    }

    @Test("Absent origin yields no presentation")
    func absentOrigin() {
        #expect(ForgePresentation(origin: nil) == nil)
    }
}

@Suite("@spec PROJECT-2.3: While a repo's origin resolves to a supported forge, the repo context menu shall include an Open on GitHub…/Open on GitLab… item opening the project URL.")
struct ForgePresentationMenuTests {
    @Test("Menu title names the forge")
    func menuTitles() {
        let gh = HostingOrigin(provider: .github, host: "github.com", owner: "a", repo: "b")
        let gl = HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "a", repo: "b")
        #expect(ForgePresentation(origin: gh)?.menuTitle == "Open on GitHub…")
        #expect(ForgePresentation(origin: gl)?.menuTitle == "Open on GitLab…")
    }

    @Test("Help text names the slug and forge")
    func helpText() {
        let gh = HostingOrigin(provider: .github, host: "github.com", owner: "a", repo: "b")
        #expect(ForgePresentation(origin: gh)?.helpText(slug: "a/b") == "Open a/b on GitHub")
    }
}
```

Append to `Tests/GrafttyTests/Views/SVGPathShapeTests.swift`, inside `SVGPathParserTests`:

```swift
    @Test("GitHub mark parses non-empty within its 16x16 viewBox")
    func githubMarkGeometry() {
        let rect = bounds(ForgePresentation.Mark.github.pathData)
        #expect(!rect.isEmpty)
        #expect(rect.minX >= -0.1 && rect.minY >= -0.1)
        #expect(rect.maxX <= 16.1 && rect.maxY <= 16.1)
    }

    @Test("GitLab mark parses non-empty within its 24x24 viewBox")
    func gitlabMarkGeometry() {
        let rect = bounds(ForgePresentation.Mark.gitlab.pathData)
        #expect(!rect.isEmpty)
        #expect(rect.minX >= -0.1 && rect.minY >= -0.1)
        #expect(rect.maxX <= 24.1 && rect.maxY <= 24.1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ForgePresentation`
Expected: compile error — `cannot find 'ForgePresentation' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Graftty/Views/ForgeLogoMark.swift`:

```swift
import SwiftUI
import GrafttyKit

/// Maps a repo's hosting origin to its sidebar presentation: which
/// forge mark to draw and the user-facing forge name. nil for
/// unsupported providers and absent origins, which render with no
/// icon at all (PROJECT-2.2).
struct ForgePresentation: Equatable {
    enum Mark: Equatable {
        case github
        case gitlab

        /// Vendored vector geometry, drawn in code rather than
        /// bundled as image assets: SF Symbols has no brand marks,
        /// and this project has shipped broken releases from
        /// resource-bundling gaps (v0.1.5, v0.1.10).
        var pathData: String {
            switch self {
            case .github:
                // Octicons `mark-github` (16x16), MIT licensed.
                return "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"
            case .gitlab:
                // Simple Icons `gitlab` (24x24), CC0.
                return "m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"
            }
        }

        var viewBox: CGSize {
            switch self {
            case .github: return CGSize(width: 16, height: 16)
            case .gitlab: return CGSize(width: 24, height: 24)
            }
        }
    }

    let mark: Mark
    let forgeName: String

    init?(origin: HostingOrigin?) {
        switch origin?.provider {
        case .github:
            mark = .github
            forgeName = "GitHub"
        case .gitlab:
            mark = .gitlab
            forgeName = "GitLab"
        case .unsupported, nil:
            return nil
        }
    }

    var menuTitle: String { "Open on \(forgeName)…" }

    func helpText(slug: String) -> String { "Open \(slug) on \(forgeName)" }
}

/// Monochrome forge logo for the sidebar's project rows, tinted by
/// the caller (theme.sidebarDimIcon) to match the other sidebar
/// chrome. @spec PROJECT-2.0
struct ForgeLogoMark: View {
    let mark: ForgePresentation.Mark
    let color: Color

    var body: some View {
        SVGPathShape(pathData: mark.pathData, viewBox: mark.viewBox)
            .fill(color, style: FillStyle(eoFill: true))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "ForgePresentation|SVGPath"`
Expected: all PASS (including the two new mark-geometry tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/ForgeLogoMark.swift Tests/GrafttyTests/Specs/ProjectTests.swift Tests/GrafttyTests/Views/SVGPathShapeTests.swift
git commit -m "feat(PROJECT-2.0,2.2,2.3): ForgePresentation mapping + code-drawn forge marks"
```

---

### Task 5: Sidebar wiring — icon button and context menu

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift` (the `repoSection(_:)` label and `.contextMenu`, currently around lines 168–209)

This is the thin view layer over the already-tested pieces; no new unit test (consistent with how other `SidebarView` wiring is handled — behavior lives in tested helpers).

- [ ] **Step 1: Add the leading forge button**

In `repoSection(_:)`, the `DisclosureGroup` label currently reads:

```swift
        } label: {
            // No leading glyph — the top level is always projects, so
            // a folder icon would be tautological noise. The disclosure
            // arrow and semibold weight carry the "expandable heading"
            // cues on their own. Trailing "+" opens the add-worktree
            // sheet; .buttonStyle(.plain) keeps its tap from toggling
            // the enclosing disclosure.
            HStack(spacing: 6) {
                Text(repo.displayName)
```

Replace that block with:

```swift
        } label: {
            // The only leading glyph is the forge mark, and only when
            // the repo's origin resolves to GitHub/GitLab — it carries
            // real information (where the project lives, click to
            // open), unlike a folder icon, which would be tautological
            // noise at a projects-only top level. The disclosure arrow
            // and semibold weight carry the "expandable heading" cues
            // on their own. Trailing "+" opens the add-worktree sheet;
            // .buttonStyle(.plain) on both buttons keeps their taps
            // from toggling the enclosing disclosure.
            HStack(spacing: 6) {
                if let origin = prStatusStore.originByRepo[repo.path],
                   let presentation = ForgePresentation(origin: origin),
                   let url = origin.webURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        ForgeLogoMark(mark: presentation.mark, color: theme.sidebarDimIcon)
                            .frame(width: 13, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(presentation.helpText(slug: origin.slug))
                }
                Text(repo.displayName)
```

(The rest of the `HStack` — `Text` modifiers, `Spacer`, the "+" button — is unchanged.)

- [ ] **Step 2: Add the context-menu item**

The repo `.contextMenu` currently reads:

```swift
            .contextMenu {
                if !repo.isGitTracked {
                    Button("Initialize Git Repository") {
                        onInitializeGit(repo)
                    }
                }
                Button("Remove Repository") {
                    onRemoveRepo(repo)
                }
            }
```

Insert the forge item between the two existing entries:

```swift
            .contextMenu {
                if !repo.isGitTracked {
                    Button("Initialize Git Repository") {
                        onInitializeGit(repo)
                    }
                }
                // @spec PROJECT-2.3
                if let origin = prStatusStore.originByRepo[repo.path],
                   let presentation = ForgePresentation(origin: origin),
                   let url = origin.webURL {
                    Button(presentation.menuTitle) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Remove Repository") {
                    onRemoveRepo(repo)
                }
            }
```

NOTE: `// @spec PROJECT-2.3` here would be a duplicate-location violation only if it were a doc comment on a type or a test — inline references in implementation comments are how existing specs are cited (`grep -n "PR-8.18" Sources` shows the pattern is `@spec` in doc comments only). To stay safe with `scripts/generate-specs.py`'s duplicate detection, write the comment WITHOUT the `@spec` keyword: `// PROJECT-2.3: context-menu forge link.` Verify by running `scripts/generate-specs.py` in Task 6 — it must not error.

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/SidebarView.swift
git commit -m "feat(PROJECT-2.0,2.1,2.3): sidebar forge logo opens the project on its forge"
```

---

### Task 6: Regenerate SPECS.md and final verification

**Files:**
- Regenerate: `SPECS.md`

- [ ] **Step 1: Regenerate the spec inventory**

Run: `python3 scripts/generate-specs.py` (use `uv run` if the script demands it; it is a plain stdlib script)
Expected: exits 0; `git diff SPECS.md` shows the five new PROJECT-2.x entries

- [ ] **Step 2: Verify no duplicate-spec errors**

Run: `python3 scripts/generate-specs.py --check`
Expected: exits 0 (SPECS.md current, no duplicate IDs)

- [ ] **Step 3: Run the full test suite one last time**

Run: `swift test`
Expected: all PASS

- [ ] **Step 4: Commit**

```bash
git add SPECS.md
git commit -m "docs: regenerate SPECS.md with PROJECT-2.x forge-link specs"
```

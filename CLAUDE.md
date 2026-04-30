# Graftty — Agent Instructions

## Keeping SPECS.md current

`SPECS.md` is auto-generated from `@spec` annotations in code. Never edit it manually.

### Writing requirements

Requirements use EARS (Easy Approach to Requirements Syntax) phrasing:

- **State-scoped:** "While `<state>`, the application shall `<behavior>`."
- **Event-scoped:** "When `<trigger>`, the application shall `<behavior>`."
- **Conditional:** "If `<condition>`, then the application shall `<behavior>`."

Each requirement gets a scoped identifier (e.g., `GIT-4.3`, `LAYOUT-2.12`) so it can be cited in PRs, commit messages, and source comments. Place new requirements under the feature section they concern (context-menu items go under their feature's section, not in a central "context menu" cluster) and extend the existing numbering rather than renumbering siblings.

### The `@spec` convention

Every requirement uses the `@spec` keyword with a spec ID and EARS text.

**In Swift Testing test titles** (behavioral specs):
```swift
@Test("@spec LAYOUT-2.14: When PaneTitle.display renders a whitespace-only stored title, the application shall fall through to the PWD basename rather than render visible blank space.")
func whitespaceOnlyTitleFallsThrough() async throws { /* … */ }
```

**In `@Suite` titles** (one spec, multiple assertions):
```swift
@Suite("@spec LAYOUT-2.13: The application shall reject OSC 2 command-echo titles produced by ghostty's preexec hook.")
struct CommandEchoTitleRejectionTests {
    @Test func rejectsNakedEnvAssignment() { /* … */ }
    @Test func rejectsZdotdirMarker() { /* … */ }
    @Test func preservesPriorTitle() { /* … */ }
}
```

**In doc comments on types** (structural / state-machine specs):
```swift
/// @spec GIT-3.0
/// Each worktree shall expose a state of one of: missing, idle, running, stale.
public enum WorktreeState: String, Codable {
    case missing, idle, running, stale
}
```

**XCTest tests** carry the `@spec` in the `///` doc comment above the test method (XCTest method names can't hold the EARS text directly):
```swift
/// @spec ATTN-1.11: `graftty pane list` shall format each line as `<focus> <id> <title>` with a single-space separator at every id width.
func testFormattedLineLayout() { /* … */ }
```

Prefer Swift Testing for new spec tests — the title-as-spec-text mapping is cleaner.

**For unimplemented specs**, add a `@Test(…, .disabled("not yet implemented"))` entry to the matching `Tests/GrafttyTests/Specs/<Prefix>Todo.swift` inventory file (one file per ID prefix — `LayoutTodo.swift`, `GitTodo.swift`, etc.):
```swift
@Test("""
@spec SEARCH-5: If no results match the query, the application shall display a 'No matches' hint with refinement suggestions.
""", .disabled("not yet implemented"))
func search_5() async throws { }
```

`*Todo.swift` files are requirement inventory only — Swift Testing compiles them but `.disabled` short-circuits execution, so backlog requirements stay grep-able and appear in `SPECS.md` without polluting the test-run report.

### Rules
- A spec ID appears in at most one behavioral location (real test OR inventory entry) and one type location.
- The same ID in both a test and a type is encouraged (dual enforcement: behavioral + structural).
- `grep -rn "@spec"` finds every requirement in the codebase.
- `*Todo.swift` files are inventory only; promote a `.disabled` test to a real `@Test` (in a `*Tests.swift` file) before implementing the behavior, and delete the inventory entry in the same commit.
- `scripts/generate-specs.py` fails if the same spec ID appears as both an active test and a disabled inventory entry, or twice in either kind. CI runs `scripts/generate-specs.py --check` (`verify-specs` job in `.github/workflows/ci.yml`) and fails when `SPECS.md` is stale relative to the annotations.
- Run `scripts/generate-specs.py` to regenerate `SPECS.md`; commit the regenerated file alongside your code change.

### When adding features
1. Write the `@spec` in a `@Test(.disabled(...))` in a `*Todo.swift` file (for backlog) or directly as a real `@Test` title (when implementing now) — this IS the requirement.
2. If the spec describes a data shape or valid states, also add a `@spec` doc comment on the corresponding type.
3. Follow the TDD process below: disabled → failing test → passing implementation.
4. Run `scripts/generate-specs.py` and commit the updated `SPECS.md`.

### When changing behavior
1. Find the existing `@spec` with `grep -rn "@spec SPEC-ID"`.
2. Update the EARS text in the test title (or `///` block, for XCTest) to match the new behavior.
3. If the same spec ID has a `@spec` doc comment on a type, update that text to match exactly.
4. Update the test assertions and implementation.
5. Run `scripts/generate-specs.py` and commit the updated `SPECS.md`.

### When removing features
1. Delete the `@spec` test and any `@spec` doc comment for that spec ID.
2. Run `scripts/generate-specs.py` — the entry will disappear from `SPECS.md`.
3. Commit the updated `SPECS.md`.

## Development process

For new features and bug fixes, follow a RED/GREEN TDD process:

1. **Find or write the `@spec`** — check whether a `@Test(.disabled(...))` already exists in a `*Todo.swift` inventory file. If not, create one with the EARS requirement text. For new features, write the spec in the test title first.
2. **Promote** the `@Test(.disabled(...))` from the `*Todo.swift` inventory file to a real `@Test` in a `*Tests.swift` file with assertions that fail (RED). Move it into a dedicated test file if the topic warrants one.
3. **Implement** the minimum code to make the test pass (GREEN).
4. **Run `swift test`** to confirm it passes (and that no other tests regressed).
5. **Run `scripts/generate-specs.py`** and commit the updated `SPECS.md` alongside your code.

## Always run /simplify before opening a PR

Before opening a PR, run `/simplify` to review the changed code for reuse, quality, and efficiency, and apply any improvements it surfaces. This catches dead code, duplicated helpers, and over-complicated branches that are easier to clean up before review than after.

## Cutting a release

Releases are tag-driven — no source changes needed to bump the version.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

`.github/workflows/release.yml` takes it from there: builds the bundle (picking up `GRAFTTY_VERSION` from the tag), ad-hoc codesigns, zips with `ditto`, attaches the zip to a GitHub release, and pushes a `version`+`sha256` bump to the `btucker/homebrew-graftty` cask tap. Bootstrap + migration notes (Developer ID + notarization) live in `docs/release/README.md`.

The release workflow does not run tests — it only runs `swift build`. A flaky `ci.yml` failure on the head commit does not block a release, but confirm the failure is unrelated to the shipped changes before tagging.

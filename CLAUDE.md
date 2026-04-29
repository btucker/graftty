# Graftty — Agent Instructions

## Keep SPECS.md in sync with behavior

Every PR that adds, changes, or removes user-visible functionality must also update `SPECS.md`. SPECS.md is the authoritative description of what the app does — code without a spec entry is not done.

Write requirements in the EARS (Easy Approach to Requirements Syntax) style already established in SPECS.md:

- **State-scoped:** "While `<state>`, the application shall `<behavior>`."
- **Event-scoped:** "When `<trigger>`, the application shall `<behavior>`."
- **Conditional:** "If `<condition>`, then the application shall `<behavior>`."

Each requirement gets a scoped identifier (e.g., `GIT-4.3`, `LAYOUT-2.12`) so it can be cited in PRs and commit messages. Place new requirements under the feature section they concern (context-menu items go under their feature's section, not in a central "context menu" cluster) and extend the existing numbering rather than renumbering siblings.

If a change removes or modifies behavior, update or delete the matching requirements in the same commit — the goal is that SPECS.md never lags behind the code.

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

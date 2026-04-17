# Homebrew Distribution — Design Specification

Ship Espalier as a Homebrew Cask installable from a personal tap, with releases built and published automatically when a `v*` git tag is pushed.

## Goal

After this ships, this user story works:

> I want to try Espalier. I run `brew tap btucker/espalier && brew install --cask espalier`. Homebrew downloads the latest release, drops `Espalier.app` into `/Applications`, and symlinks the bundled CLI onto my PATH so `espalier --help` works in my terminal. I right-click the app once to clear the Gatekeeper warning (until notarization lands), and I'm running.

For the maintainer (Ben):

> I bump the version, run `git tag v0.2.0 && git push origin v0.2.0`. Within a few minutes, GitHub Actions has built the release-mode bundle, ad-hoc signed it, zipped it, attached the zip to a fresh GitHub release, and pushed an updated `Casks/espalier.rb` to the tap. No further manual steps.

## Scope

This spec covers the **personal-tap + ad-hoc-signed** path. Out of scope:

- Submission to `homebrew/cask` upstream (planned later, after the project is past 0.x and has notarization)
- Developer ID signing and Apple notarization (planned for after Apple Dev ID approval — same workflow skeleton, additional signing identity and `notarytool submit` steps)
- DMG artifact (zip handles both Homebrew install and direct download)
- In-app auto-update (Sparkle, etc.)

## Architecture

The system has four components — three living in `btucker/espalier` and one in a new tap repo:

```
btucker/espalier (this repo)            btucker/homebrew-espalier (new)
├── scripts/bundle.sh        ┐          └── Casks/espalier.rb
│   (version-aware,          │              ↑
│    ad-hoc signed)          │              │ updated on each release
├── .github/workflows/       │              │ via cross-repo PAT
│   release.yml              ┴──────────────┘
└── Sources/...
```

The release workflow is the integration point — everything else is independently testable.

### Component 1: Version-aware `bundle.sh`

Today `scripts/bundle.sh` hardcodes `0.1.0` in the Info.plist heredoc. With tag-driven releases this immediately drifts. Change the script to:

- Read `ESPALIER_VERSION` from environment, defaulting to `0.0.0-dev` for local builds
- Substitute that value into both `CFBundleShortVersionString` and `CFBundleVersion`
- Print the version it's building at the start of the run, so local invocations are unambiguous

Implementation: replace the static heredoc with one that interpolates `$ESPALIER_VERSION`, or write the plist via `/usr/libexec/PlistBuddy` after templating. Either works; the heredoc edit is smaller.

### Component 2: Ad-hoc codesigning step in `bundle.sh`

After all binaries are in place but before "✓ Bundle at …", sign every Mach-O in the bundle, inner-out:

```bash
codesign --force --sign - "$APP/Contents/Helpers/zmx"
codesign --force --sign - "$APP/Contents/Helpers/espalier"
codesign --force --sign - "$APP/Contents/MacOS/Espalier"
codesign --force --sign - "$APP"
```

`--sign -` is the ad-hoc identity (no Developer ID required). Inner binaries first because Apple's nesting rules require nested code to already be signed when the outer container is signed; otherwise the outer signature does not cover them and the runtime rejects the bundle. No `--deep` flag — Apple deprecated it in favor of explicit per-component signing, which is also what notarization will require.

When notarization lands, this stanza is the only place that changes — same structure, real Developer ID identity, plus `--options runtime` for the hardened runtime requirement.

### Component 3: Release workflow — `.github/workflows/release.yml`

Trigger:

```yaml
on:
  push:
    tags: ['v*']
```

Runs on `macos-14`. Steps:

1. Checkout (full history not required, but `fetch-depth: 0` is harmless and helps if the script ever wants `git describe`)
2. Select stable Xcode (whatever the existing CI workflow pins)
3. Extract version: `VERSION=${GITHUB_REF_NAME#v}` (strip leading `v`, fail loudly if it's not there)
4. `CONFIGURATION=release ESPALIER_VERSION="$VERSION" scripts/bundle.sh`
5. Zip with `ditto -c -k --keepParent .build/Espalier.app "Espalier-$VERSION.zip"` (`ditto` over `zip` because it preserves resource forks and extended attributes that `codesign` cares about)
6. Compute sha256: `shasum -a 256 "Espalier-$VERSION.zip"`
7. Create the release: `gh release create "v$VERSION" "Espalier-$VERSION.zip" --generate-notes` (uses default `GITHUB_TOKEN`, scoped to this repo)
8. Update the tap (see below) — uses cross-repo `HOMEBREW_TAP_TOKEN` PAT

#### Tap update step (within the release workflow)

```bash
git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/btucker/homebrew-espalier.git" tap
cd tap
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" Casks/espalier.rb
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" Casks/espalier.rb
git config user.name  "espalier-release-bot"
git config user.email "espalier-release-bot@users.noreply.github.com"
git commit -am "espalier $VERSION"
git push
```

Direct push (not PR) to the tap's `main` since it's a personal tap and there's no review workflow to gate on. Two `sed` calls instead of one because keeping them separate makes the failure mode obvious if either field's literal text drifts in the cask.

### Component 4: The cask file — `Casks/espalier.rb`

```ruby
cask "espalier" do
  version "0.1.0"
  sha256 "..."

  url "https://github.com/btucker/espalier/releases/download/v#{version}/Espalier-#{version}.zip"
  name "Espalier"
  desc "Worktree-aware terminal multiplexer"
  homepage "https://github.com/btucker/espalier"

  depends_on macos: ">= :sonoma"

  app "Espalier.app"
  binary "#{appdir}/Espalier.app/Contents/Helpers/espalier"

  zap trash: [
    "~/Library/Application Support/Espalier",
    "~/Library/Preferences/com.espalier.app.plist",
    "~/Library/Caches/com.espalier.app",
  ]

  caveats <<~EOS
    Espalier is currently ad-hoc signed (not notarized). On first launch,
    macOS will refuse to open it. Right-click Espalier in Applications and
    choose "Open" to approve it once.
  EOS
end
```

Key points:

- `binary "#{appdir}/Espalier.app/Contents/Helpers/espalier"` — Homebrew creates `/opt/homebrew/bin/espalier` as a symlink into the app bundle. No copy, no second source of truth. When the cask uninstalls, the symlink is removed automatically.
- `depends_on macos: ">= :sonoma"` matches `LSMinimumSystemVersion` 14.0 in the Info.plist.
- `zap` runs only on `brew uninstall --zap`. The trio listed mirrors what the app actually writes (Application Support for app data, Preferences plist for `@AppStorage`, Caches for transient data). Nothing under `~/Library/LaunchAgents` because Espalier ships no agents.
- `caveats` exists only until notarization lands; deletable in one PR thereafter.

## One-time setup the user does by hand

Before the first tagged release can succeed:

1. Create empty public repo `btucker/homebrew-espalier` on GitHub
2. Create a fine-grained PAT scoped to that repo with **Contents: read & write** permission. Save as repository secret `HOMEBREW_TAP_TOKEN` on `btucker/espalier`.
3. Commit an initial `Casks/espalier.rb` to the tap (the workflow updates it in-place via `sed`, so the file has to exist with the literal `version "..."` and `sha256 "..."` lines for `sed` to match). Initial values can be placeholders — they'll be overwritten on the first release.

After this, every `git tag v*.*.* && git push --tags` is hands-off.

## Build sequence per release

```
Tag pushed: v0.2.0
   │
   ▼
GitHub Actions: release.yml on macos-14
   │
   ├─ swift build --configuration release
   ├─ scripts/bundle.sh (with ESPALIER_VERSION=0.2.0)
   │     └─ codesign --sign - all Mach-Os, inner→outer
   ├─ ditto -c -k --keepParent → Espalier-0.2.0.zip
   ├─ shasum -a 256 → SHA256
   ├─ gh release create v0.2.0 Espalier-0.2.0.zip
   └─ clone tap, sed version+sha256, commit, push
   │
   ▼
brew update + brew install --cask espalier picks up new version
```

## Failure modes and recovery

- **Codesign fails on `zmx`**: vendored binary may be missing executable bit or have stale `__LINKEDIT`. Fix in `Resources/zmx-binary/zmx` and re-tag (or use `bump-zmx.sh`).
- **`sed` no-ops in tap**: the cask file's `version "..."` or `sha256 "..."` line was hand-edited into a form `sed` doesn't match. Fix the cask manually, then the next release will work again. (A more defensive alternative — generating the cask from a template — is YAGNI for one cask file.)
- **Tag pushed but workflow didn't run**: confirm the tag matches `v*` (workflow trigger filter), and that `Actions` are enabled on the repo.
- **`brew install --cask` says "checksum mismatch"**: the zip on Releases doesn't match the sha256 the cask declared. Almost always means the workflow uploaded the zip but the tap update step failed mid-run. Re-run the failed workflow job; both steps are idempotent (gh release create supports `--clobber`-ish via re-upload, the tap commit will be a no-op).

## Testing

Local sanity (no network):

```bash
ESPALIER_VERSION=0.0.0-test scripts/bundle.sh
codesign --verify --verbose=2 .build/Espalier.app
codesign --display --verbose=2 .build/Espalier.app
```

Workflow shakedown (cuts a real release; fine for v0.0.0-rc tags):

```bash
git tag v0.0.0-rc1
git push origin v0.0.0-rc1
# Watch Actions → confirm release zip appears, tap commit lands
```

End-to-end (on a clean Mac or fresh Homebrew prefix):

```bash
brew tap btucker/espalier
brew install --cask espalier
espalier --help                   # CLI symlink works
open /Applications/Espalier.app   # app launches (after first-run Gatekeeper override)
brew uninstall --cask --zap espalier
ls ~/Library/Application\ Support/Espalier 2>/dev/null  # zap removed it
```

## Future extensions

- **Developer ID signing + notarization**: replace `--sign -` with `--sign "Developer ID Application: …"` + `--options runtime`, add a `notarytool submit --wait` step before zip creation, staple the ticket. Drop the `caveats` stanza. All other components unchanged.
- **DMG artifact**: add a `create-dmg` step in the workflow alongside the zip; cask gains a second `url`/`sha256` only if the project ever wants to default to DMG.
- **Submission to `homebrew/cask`**: copy the cask file into a fork of `homebrew/cask`, open a PR. Tap stays in place as a backup channel; both can coexist.
- **Auto-bumping via `dependabot` or `brew bump-cask-pr`**: irrelevant for a self-published tap, becomes useful only if the cask graduates to homebrew-cask upstream.

# Homebrew Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Espalier as a Homebrew Cask installable from a personal tap, with releases built and published automatically when a `v*` git tag is pushed.

**Architecture:** Three things change in this repo (`scripts/bundle.sh`, a new `.github/workflows/release.yml`, and a documentation drop containing the initial cask file the user copies to the tap). One thing happens by hand outside the repo (creating the tap repo + a PAT secret). After that, every `git tag v*.*.* && git push --tags` produces a signed zip on GitHub Releases and pushes a cask bump to the tap.

**Tech Stack:** Bash, GitHub Actions, macOS `codesign`, `ditto`, Homebrew Cask DSL (Ruby), `gh` CLI.

**Reference spec:** `docs/superpowers/specs/2026-04-17-homebrew-distribution-design.md`

---

## File Structure

**Modified files:**
- `scripts/bundle.sh` — read `ESPALIER_VERSION` env var, substitute into `Info.plist`, ad-hoc codesign every Mach-O inner-out
- `SPECS.md` — add Section 14: Distribution

**New files:**
- `.github/workflows/release.yml` — tag-triggered build → sign → zip → release → tap update workflow
- `docs/release/Casks/espalier.rb` — reference cask file content the user commits once into the tap repo
- `docs/release/README.md` — one-time setup instructions for the tap repo and PAT secret

---

## Task 1: Make `bundle.sh` version-aware

The current `bundle.sh` writes a heredoc with quoted delimiter (`<<'PLIST'`) that prevents shell expansion, hardcoding `0.1.0`. We change the delimiter to unquoted (`<<PLIST`) so `$ESPALIER_VERSION` interpolates, and we read that variable from the environment with a `0.0.0-dev` default for local builds.

**Files:**
- Modify: `scripts/bundle.sh`

- [ ] **Step 1: Add version variable near the top of the script**

Edit `scripts/bundle.sh`. Find this block near line 17:

```bash
CONFIGURATION="${CONFIGURATION:-debug}"

echo "→ swift build --configuration $CONFIGURATION"
```

Replace with:

```bash
CONFIGURATION="${CONFIGURATION:-debug}"
ESPALIER_VERSION="${ESPALIER_VERSION:-0.0.0-dev}"

echo "→ ESPALIER_VERSION=$ESPALIER_VERSION"
echo "→ swift build --configuration $CONFIGURATION"
```

- [ ] **Step 2: Make the Info.plist heredoc interpolate the version**

In the same file, find the Info.plist generation:

```bash
cat > "$APP/Contents/Info.plist" <<'PLIST'
```

Change the delimiter from quoted to unquoted so shell variables expand:

```bash
cat > "$APP/Contents/Info.plist" <<PLIST
```

Then in the body of the heredoc, replace these two lines:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
```

With:

```xml
    <key>CFBundleShortVersionString</key>
    <string>$ESPALIER_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$ESPALIER_VERSION</string>
```

(Both keys take the same value. `CFBundleVersion` is supposed to be a build number, but for tag-driven releases the cleanest source of truth is the tag itself; downstream Homebrew/Sparkle/etc. only read `CFBundleShortVersionString`.)

The closing delimiter stays as `PLIST` (delimiters are matched by string identity, not quoting).

- [ ] **Step 3: Verify default-version local build**

Run:

```bash
cd /Users/btucker/projects/espalier/.worktrees/homebrew-setup
scripts/bundle.sh
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" .build/Espalier.app/Contents/Info.plist
```

Expected output: `0.0.0-dev`

- [ ] **Step 4: Verify env-overridden build**

Run:

```bash
ESPALIER_VERSION=0.0.0-test scripts/bundle.sh
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" .build/Espalier.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" .build/Espalier.app/Contents/Info.plist
```

Expected output:

```
0.0.0-test
0.0.0-test
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bundle.sh
git commit -m "build: make bundle.sh read ESPALIER_VERSION from env

Switches the Info.plist heredoc from quoted ('PLIST') to unquoted
(PLIST) so shell variable expansion works, then sources
CFBundleShortVersionString and CFBundleVersion from \$ESPALIER_VERSION,
defaulting to 0.0.0-dev for local builds. The release workflow will
set this from the pushed git tag."
```

---

## Task 2: Add ad-hoc codesigning to `bundle.sh`

Sign every Mach-O in the bundle, inner-out, with the ad-hoc identity (`-`). No `--deep` — Apple deprecated it, and explicit per-component signing is also what notarization will require.

**Files:**
- Modify: `scripts/bundle.sh`

- [ ] **Step 1: Add codesign block before the success message**

Edit `scripts/bundle.sh`. Find this block at the bottom:

```bash
PLIST

echo "✓ Bundle at $APP"
```

Insert a codesign step between the `PLIST` heredoc terminator and the success message:

```bash
PLIST

echo "→ ad-hoc codesign (inner → outer)"
# Sign helpers first, then the main binary, then the bundle itself.
# Apple's nesting rules require nested code to already be signed when
# the outer container is signed; otherwise the outer signature does
# not cover them and the runtime rejects the bundle. When we move to
# Developer ID + notarization, this is the one block that changes
# (real identity + --options runtime).
codesign --force --sign - "$APP/Contents/Helpers/zmx"
codesign --force --sign - "$APP/Contents/Helpers/espalier"
codesign --force --sign - "$APP/Contents/MacOS/Espalier"
codesign --force --sign - "$APP"

echo "✓ Bundle at $APP"
```

- [ ] **Step 2: Verify the bundle passes `codesign --verify`**

Run:

```bash
scripts/bundle.sh
codesign --verify --strict --verbose=2 .build/Espalier.app
```

Expected output (last two lines):

```
.build/Espalier.app: valid on disk
.build/Espalier.app: satisfies its Designated Requirement
```

- [ ] **Step 3: Verify each helper is individually signed**

Run:

```bash
codesign --display --verbose=2 .build/Espalier.app/Contents/Helpers/zmx 2>&1 | grep -E "Signature|Identifier"
codesign --display --verbose=2 .build/Espalier.app/Contents/Helpers/espalier 2>&1 | grep -E "Signature|Identifier"
```

Expected: each command prints a `Signature=adhoc` line (i.e., signed with ad-hoc identity, not unsigned).

- [ ] **Step 4: Commit**

```bash
git add scripts/bundle.sh
git commit -m "build: ad-hoc codesign bundle in bundle.sh

Signs every Mach-O in the bundle inner-out: zmx, the espalier CLI
helper, the main Espalier binary, then the bundle itself. Ad-hoc
identity (--sign -) — no Developer ID required. When notarization
lands, this block flips to a real identity plus --options runtime;
the structure stays the same."
```

---

## Task 3: Create the release workflow

Triggered on `push: tags: ['v*']`. Builds release-mode bundle, verifies signing, zips with `ditto`, computes sha256, creates the GitHub release, and pushes a cask bump to the tap repo using a cross-repo PAT.

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflow file**

Write `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    # macos-26 mirrors the CI workflow — same Xcode, same Swift, same
    # toolchain quirks already known to work for this repo.
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Show tool versions
        run: |
          swift --version
          xcodebuild -version

      - name: Extract version from tag
        id: version
        run: |
          set -euo pipefail
          VERSION="${GITHUB_REF_NAME#v}"
          if [ "$VERSION" = "$GITHUB_REF_NAME" ]; then
            echo "Tag must start with 'v' — got '$GITHUB_REF_NAME'" >&2
            exit 1
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - name: Build app bundle
        env:
          CONFIGURATION: release
          ESPALIER_VERSION: ${{ steps.version.outputs.version }}
        run: scripts/bundle.sh

      - name: Verify codesign
        run: codesign --verify --strict --verbose=2 .build/Espalier.app

      - name: Zip artifact
        id: zip
        env:
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          set -euo pipefail
          ZIP="Espalier-$VERSION.zip"
          # ditto preserves resource forks and extended attributes that
          # codesign cares about; plain `zip` strips them.
          ditto -c -k --keepParent .build/Espalier.app "$ZIP"
          SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
          echo "zip=$ZIP" >> "$GITHUB_OUTPUT"
          echo "sha256=$SHA256" >> "$GITHUB_OUTPUT"
          echo "Zip: $ZIP ($SHA256)"

      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ steps.version.outputs.version }}
          ZIP: ${{ steps.zip.outputs.zip }}
        run: |
          set -euo pipefail
          gh release create "v$VERSION" "$ZIP" \
            --title "v$VERSION" \
            --generate-notes

      - name: Update Homebrew tap
        env:
          HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
          VERSION: ${{ steps.version.outputs.version }}
          SHA256: ${{ steps.zip.outputs.sha256 }}
        run: |
          set -euo pipefail
          git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/btucker/homebrew-espalier.git" tap
          cd tap
          # Rewrite version + sha256 in place. Two seds (not one) so the
          # failure mode is obvious if either field's literal text drifts
          # in the cask.
          sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" Casks/espalier.rb
          sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" Casks/espalier.rb
          git config user.name  "espalier-release-bot"
          git config user.email "espalier-release-bot@users.noreply.github.com"
          git add Casks/espalier.rb
          if git diff --cached --quiet; then
            echo "No cask changes — re-releasing the same version?"
            exit 0
          fi
          git commit -m "espalier $VERSION"
          git push
```

- [ ] **Step 2: Verify the YAML parses**

Run:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo OK
```

Expected output: `OK` (no exception).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow on tag push

Triggers on git tags matching v*. Builds release-mode bundle via
scripts/bundle.sh (which now reads ESPALIER_VERSION from env),
verifies codesigning, zips with ditto (preserves codesign-relevant
xattrs that plain zip strips), creates a GitHub release, and pushes
a version+sha256 bump to the btucker/homebrew-espalier tap using
the HOMEBREW_TAP_TOKEN secret."
```

---

## Task 4: Provide initial cask file + release docs

The cask file lives in the *tap* repo (`btucker/homebrew-espalier`), not here — the workflow updates it via `sed` so it has to exist with the literal `version "..."` and `sha256 "..."` lines for `sed` to match. We ship the initial content as a reference under `docs/release/Casks/espalier.rb` plus a README explaining the one-time setup.

**Files:**
- Create: `docs/release/Casks/espalier.rb`
- Create: `docs/release/README.md`

- [ ] **Step 1: Create the reference cask file**

Write `docs/release/Casks/espalier.rb`:

```ruby
cask "espalier" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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

The `version "0.0.0"` and zero-filled `sha256` are placeholders — the release workflow's `sed` step rewrites both on first publish.

- [ ] **Step 2: Create the release docs README**

Write `docs/release/README.md`:

```markdown
# Releasing Espalier

Espalier is distributed as a Homebrew Cask from the personal tap
[`btucker/homebrew-espalier`](https://github.com/btucker/homebrew-espalier).
The `.github/workflows/release.yml` workflow handles per-release work:
it builds the bundle, ad-hoc codesigns it, zips it, attaches the zip to
a GitHub release, and pushes a version+sha256 bump to the tap.

## One-time setup

These steps need to happen once, by hand, before the first tagged
release will succeed.

### 1. Create the tap repository

Create an empty public repository on GitHub named exactly
`btucker/homebrew-espalier`. The `homebrew-` prefix is what makes
`brew tap btucker/espalier` resolvable by the short name.

### 2. Create a Personal Access Token for cross-repo writes

Go to GitHub → Settings → Developer settings → Personal access tokens
→ Fine-grained tokens → Generate new token.

- Name: `espalier-release-bot` (any name; this is just a label)
- Expiration: 1 year (renew as needed)
- Repository access: Only select repositories → `btucker/homebrew-espalier`
- Repository permissions: **Contents: Read and write**
- (Leave all other permissions at "no access".)

Copy the generated token. Then on `btucker/espalier` go to Settings →
Secrets and variables → Actions → New repository secret. Name it
**`HOMEBREW_TAP_TOKEN`** and paste the token value.

### 3. Bootstrap the tap with the initial cask file

Copy `docs/release/Casks/espalier.rb` from this repo into the tap
repo at the same path:

```bash
cd /tmp
git clone git@github.com:btucker/homebrew-espalier.git
mkdir -p homebrew-espalier/Casks
cp /path/to/espalier/docs/release/Casks/espalier.rb homebrew-espalier/Casks/espalier.rb
cd homebrew-espalier
git add Casks/espalier.rb
git commit -m "Initial cask"
git push
```

The `version "0.0.0"` and zero-filled `sha256` are placeholders; the
release workflow rewrites both on the first real release.

## Cutting a release

Once setup is complete:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Watch GitHub Actions on `btucker/espalier`. The `release` workflow
will build, sign, zip, publish, and bump the cask. Within a few
minutes:

```bash
brew tap btucker/espalier        # one-time per machine
brew install --cask espalier
espalier --help
```

## Migration path: Developer ID + notarization

Once an Apple Developer ID Application certificate is available, the
single change is in `scripts/bundle.sh`'s codesign block: swap
`--sign -` (ad-hoc) for `--sign "Developer ID Application: …"` and
add `--options runtime`. Then the release workflow gains a
`xcrun notarytool submit … --wait` step before zipping, plus
`xcrun stapler staple` after notarization completes. Drop the
`caveats` stanza from the cask file in the same change. Nothing else
in this pipeline moves.
```

- [ ] **Step 3: Commit**

```bash
git add docs/release/Casks/espalier.rb docs/release/README.md
git commit -m "docs(release): initial cask reference + tap setup README

Provides the literal cask file the user copies into the
btucker/homebrew-espalier tap repo on first-time setup, plus a
README walking through tap creation, PAT generation, and the
HOMEBREW_TAP_TOKEN secret. Placeholder version/sha256 in the cask
get rewritten by the release workflow on first publish."
```

---

## Task 5: Update SPECS.md with distribution requirements

Per `CLAUDE.md`, every PR that adds user-visible functionality must update `SPECS.md`. Distribution behavior is user-visible — this is how users install and update Espalier.

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Add Section 14 at the end of SPECS.md**

Append the following to the end of `SPECS.md`. (Keep the existing trailing newline — append after the last existing section.)

```markdown

## 14. Distribution

### 14.1 Build Bundle

**DIST-1.1** The build script (`scripts/bundle.sh`) shall produce a self-contained `Espalier.app` bundle in `.build/` containing the SwiftUI application binary at `Contents/MacOS/Espalier`, the CLI helper at `Contents/Helpers/espalier`, and the bundled `zmx` binary at `Contents/Helpers/zmx`.

**DIST-1.2** While the `ESPALIER_VERSION` environment variable is set, the build script shall write that value into both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.

**DIST-1.3** If the `ESPALIER_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.

**DIST-1.4** The build script shall ad-hoc codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/espalier`, `Contents/MacOS/Espalier`, then the bundle itself.

### 14.2 Release Automation

**DIST-2.1** When a git tag matching `v*` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Espalier-<version>.zip`, attach the zip to a new GitHub release tagged `v<version>`, and push an updated cask file to the `btucker/homebrew-espalier` tap with the new version and sha256.

**DIST-2.2** If the pushed tag does not start with `v`, then the release workflow shall fail before building.

### 14.3 Homebrew Cask

**DIST-3.1** The Homebrew tap `btucker/homebrew-espalier` shall expose a cask `espalier` that downloads the release zip, installs `Espalier.app` to `/Applications`, and symlinks `Espalier.app/Contents/Helpers/espalier` onto the user's PATH as `espalier`.

**DIST-3.2** While the application is ad-hoc signed (not Developer ID notarized), the cask shall display a `caveats` notice instructing users to right-click the application on first launch to clear the Gatekeeper restriction.

**DIST-3.3** When the user runs `brew uninstall --cask --zap espalier`, the cask shall remove `~/Library/Application Support/Espalier`, `~/Library/Preferences/com.espalier.app.plist`, and `~/Library/Caches/com.espalier.app`.
```

- [ ] **Step 2: Verify SPECS.md still parses cleanly**

Run:

```bash
grep -c "^### 14\." SPECS.md
```

Expected output: `3` (three subsections under §14).

Run:

```bash
grep -E "^\*\*DIST-" SPECS.md | wc -l | awk '{print $1}'
```

Expected output: `9` (nine DIST requirements: 1.1–1.4, 2.1–2.2, 3.1–3.3).

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): add Section 14 — Distribution requirements

DIST-1.x: bundle.sh produces a versioned, ad-hoc-signed Espalier.app.
DIST-2.x: tag-driven GitHub Actions release workflow.
DIST-3.x: Homebrew cask installs the app and symlinks the CLI."
```

---

## Done state

After all five tasks land:

- `scripts/bundle.sh` produces a versioned, ad-hoc-signed bundle
- `.github/workflows/release.yml` exists and parses
- `docs/release/` has the initial cask + setup README
- `SPECS.md` has Section 14
- The branch is ready to merge

The user then completes the one-time tap setup from `docs/release/README.md` (create repo, create PAT, commit initial cask) and cuts a real release with `git tag v0.1.0 && git push origin v0.1.0`.

End-to-end smoke test, after the first real release lands:

```bash
brew tap btucker/espalier
brew install --cask espalier
espalier --help
open /Applications/Espalier.app    # right-click first launch for Gatekeeper
brew uninstall --cask --zap espalier
ls ~/Library/Application\ Support/Espalier 2>/dev/null    # zap removed it
```

# Self-Update via Sparkle — Design

Status: Approved 2026-04-23 · Branch: `selfupdate`

## Problem

Graftty is distributed via a Homebrew cask tap (`btucker/homebrew-graftty`) with GitHub Releases as the source of truth. The brew-driven update path has proven unreliable in practice — users running older builds don't get new versions in a timely way. Other Mac apps in this category (Ghostty, Transmission, Arc, Tower, etc.) ship their own in-app updaters, and Graftty should too.

The goal: when a user is running a Graftty version older than the latest release, the app detects that on its own, tells the user without interrupting them, lets them install with one click, and then replaces itself and relaunches.

## Non-goals

- Beta / pre-release channel support. The appcast structure leaves room for one, but we ship stable-only.
- Delta updates. We ship the whole zip on every release.
- Custom update-UI. Sparkle's standard install dialog is good enough; we only customize the trigger (a non-modal titlebar badge) and suppress Sparkle's default modal-on-scheduled-check behavior.
- Migrating to Developer ID + notarization as part of this work. Sparkle is compatible with both ad-hoc signing (today) and Developer ID (later); the updater does not need to change when that migration happens.

## Approach

Adopt Sparkle 2 (`github.com/sparkle-project/Sparkle`). Sparkle owns the parts that are fiddly and easy to get wrong: appcast fetching, version comparison, EdDSA verification of the downloaded zip, bundled installer helper that replaces the running app atomically, quit-and-relaunch orchestration. Graftty owns the trigger UI (a titlebar badge), the user driver (so scheduled-check discoveries are gentle rather than modal), the release-pipeline changes that produce a signed appcast entry, and the Homebrew cask change that stops `brew upgrade` from fighting Sparkle.

Appcast hosting: committed as `appcast.xml` on `main` in the source repo, served from `https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml`. History lives in git; the release workflow already has write access (it also pushes the cask update); no new infrastructure needed. If usage ever outgrows `raw.githubusercontent.com`'s soft rate limits, this becomes a one-time URL swap to GitHub Pages.

## Architecture

### Dependency

Add to `Package.swift`:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
```

Sparkle exports as a single `Sparkle` product; consumed by `GrafttyKit` and the main `Graftty` app target.

### New module: `Sources/GrafttyKit/Updater/`

Three files, each with one clear responsibility:

**`UpdaterController.swift`** — the boundary between the app and Sparkle. Wraps `SPUStandardUpdaterController`. Exposes an `ObservableObject` with `@Published` state:

- `updateAvailable: Bool`
- `availableVersion: String?`
- `canCheckForUpdates: Bool` (mirrors `SPUUpdater.canCheckForUpdates`)

And methods:

- `checkForUpdatesInBackground()` — called on app launch after a small delay.
- `checkForUpdatesWithUI()` — user-triggered via menu; always shows Sparkle's dialog.
- `installAvailableUpdate()` — user-triggered by clicking the titlebar badge; presents Sparkle's install dialog.

The controller is instantiated once in `GrafttyApp` and injected into the environment. The rest of the app sees only this protocol, not Sparkle types directly.

**`UpdaterUserDriver.swift`** — conforms to `SPUUserDriver`. This is where the "gentle" behavior lives. `SPUStandardUserDriver` (Sparkle's default) shows a modal alert when a scheduled check finds an update. Our custom driver:

- On `showUpdateFound(with:state:reply:)` during a *scheduled* check: stores the update info in `UpdaterController`'s `@Published` state, defers the reply to a sentinel ("user hasn't acted yet"), does not present any UI. The badge renders based on the published state.
- On *user-initiated* checks (from the menu): falls through to a `SPUStandardUserDriver` instance so the user gets the familiar dialog.
- When the user clicks the badge, we route through `installAvailableUpdate()` which resolves the deferred reply with "install" and lets `SPUStandardUserDriver` take over for the download+progress+install flow.

The split (custom driver wraps standard driver, switching on scheduled vs. user-initiated) is the cleanest way to get gentle discovery without reimplementing Sparkle's install UI.

**`UpdaterTitlebarAccessory.swift`** — an `NSViewController` whose view hosts a SwiftUI `UpdateBadge` view. Installed on the main `NSWindow` via `addTitlebarAccessoryViewController(_:)` with `layoutAttribute = .leading`, so the accessory sits in the titlebar row immediately right of the traffic lights. Hidden (`isHidden = true` on the accessory's view) when `!updateAvailable`; visible otherwise. The SwiftUI badge subscribes to the `UpdaterController`'s published state.

### Badge UI

Hidden when no update is available.

When available: a small pill-shaped button, sidebar-theme-tinted, displaying `arrow.down.circle.fill` + the short version string (e.g. `v0.2.3`). Hover tooltip: "Update to Graftty v0.2.3 available". Click → `installAvailableUpdate()`, which hands control to `SPUStandardUserDriver` for the rest of the flow (release notes, install now / install on quit / skip).

### Menu integration

Two menu items added to the app menu (first menu, "Graftty"):

- **Check for Updates…** — calls `checkForUpdatesWithUI()`. Positioned as the second item, after "About Graftty" (standard macOS placement).
- **Automatically Check for Updates** — toggle bound to Sparkle's `SUEnableAutomaticChecks` user-default.

Placement is in the existing `.commands { CommandGroup(after: .appInfo) { … } }` slot in `GrafttyApp`.

### First-launch consent

Sparkle shows a one-time "Would you like Graftty to automatically check for updates?" prompt the first time the app launches without `SUEnableAutomaticChecks` set in `UserDefaults`. We don't set the key in `Info.plist` — that would skip the prompt and opt the user in without asking. The user's choice persists in `UserDefaults` under Sparkle's own keys.

### Info.plist additions

Added to `scripts/bundle.sh`'s heredoc:

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PLACEHOLDER_UNTIL_KEY_GENERATED</string>
```

The `SUPublicEDKey` value is the base64-encoded public half of the EdDSA keypair generated during one-time setup (see "Release pipeline changes"). This is a publicly shipped value; its secrecy is not required (the private key is the secret).

### zmx and relaunch safety

zmx is a separate daemon (`Contents/Helpers/zmx`) that owns the PTY for every Graftty pane. Shells keep running inside zmx sessions across Graftty process death and relaunch — this is the same mechanism that makes terminals survive a user-initiated quit+reopen today.

When Sparkle replaces `Graftty.app` and relaunches the new version, the new Graftty re-attaches to existing zmx sessions on startup. Shells don't die. "Install Now" mid-session is therefore safe — the user's running `claude`, `vim`, `npm run dev`, etc. keep going, and the reattach happens transparently.

This property is load-bearing for the "Install Now" path being usable day-to-day, and gets its own SPECS.md requirement (`UPDATE-1.7`) so it can't silently regress.

## Release pipeline changes

### `.github/workflows/release.yml`

Three new steps, inserted between existing `Zip artifact` and `Create GitHub release`:

**Step: Build `sign_update`** — checkout and `swift build -c release --product sign_update` on `sparkle-project/Sparkle` at the same tag our package resolves to. Cache the built binary across workflow runs keyed on that tag. Runs once per release; the tool itself is ~a few seconds to rebuild if the cache misses.

**Step: Sign the zip** —

```bash
ED_SIGNATURE=$(echo -n "$SPARKLE_ED_PRIVATE_KEY" | \
  ./sign_update --ed-key-file - "$ZIP")
echo "ed_signature=$ED_SIGNATURE" >> "$GITHUB_OUTPUT"
echo "length=$(stat -f %z "$ZIP")" >> "$GITHUB_OUTPUT"
```

`SPARKLE_ED_PRIVATE_KEY` is a GitHub Actions secret set once during setup.

**Step: Update appcast on main** — checks out `main`, runs a small Swift script (lives at `scripts/appcast-update.swift`) that:

1. Reads the existing `appcast.xml` (or seeds an empty `<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">…</rss>` shell on first run).
2. Prepends a new `<item>` with:
   - `<title>Version $VERSION</title>`
   - `<sparkle:version>$VERSION</sparkle:version>` and `<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>` (single-series versioning — we use the same string for both)
   - `<pubDate>` (RFC 822)
   - `<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>` (matches `Info.plist`'s `LSMinimumSystemVersion`)
   - `<description><![CDATA[…]]></description>` — release notes body from `gh release view v$VERSION --json body --jq .body`
   - `<enclosure url="https://github.com/btucker/graftty/releases/download/v$VERSION/Graftty-$VERSION.zip" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE" />`
3. Writes the file back and commits with the existing `graftty-release-bot` identity, then pushes to `main`.

The writer script is in Swift (not sed/awk) because the appcast is XML and we want actual XML library handling — escaping release-notes bodies with backticks or angle brackets the naive way is a latent-bug generator. `XMLDocument` from `Foundation` handles this. The script is short; keeping it in-repo avoids a new tooling dependency.

**Concurrency:** the workflow already has `concurrency: release` (cancel-in-progress: false), so two tag pushes can't race the appcast commit. A rerun of a partially-failed workflow is safe — the script is idempotent on version (skips if an item with the same `sparkle:version` already exists).

### Homebrew cask (`docs/release/Casks/graftty.rb`)

Add `auto_updates true`. This is a one-time change. It tells `brew upgrade` "this cask self-updates, so a version mismatch between what brew thinks is installed and what's actually on disk is not a reason to re-download." That stops the fight between Sparkle's in-place update and brew's update check.

The existing release workflow only rewrites `version` and `sha256` in the tap copy of the cask, so we also need a one-time manual sync of this change into the tap repo (documented in `docs/release/README.md` "Keeping the cask in sync" — already notes exactly this constraint).

### One-time setup (documented in `docs/release/README.md`)

1. **Generate EdDSA keypair.** Install Sparkle's tools (`brew install --cask sparkle`), run `generate_keys`. The public key goes into `scripts/bundle.sh`'s Info.plist heredoc as `SUPublicEDKey`. The private key is added to GitHub repo secrets as `SPARKLE_ED_PRIVATE_KEY`. The private key is also stored in the developer's keychain by `generate_keys` as a backup — do not lose it, there is no recovery path (a lost key means every user has to manually re-download and trust a new key baked into a new release).
2. **Seed `appcast.xml`** on `main` with an empty `<rss>` shell. One commit.
3. **Publish the public-key change + appcast feed-URL** in a release tagged `v0.X.0` before any user has it installed. Existing installs that predate self-update do not auto-upgrade — users on pre-`v0.X.0` get it via the next `brew upgrade` (which still works today, and they receive a version with Sparkle baked in for future updates).
4. **Add `auto_updates true` to the tap repo's cask** in the same push that ships `v0.X.0`.

## Testing

**Unit tests (`Tests/GrafttyKitTests/UpdaterTests.swift`):**
- `UpdaterController` state transitions driven by a mock conforming to the Sparkle-wrapping protocol (not `SPUUpdater` directly — we test the Swift boundary).
- `UpdaterUserDriver` routes scheduled-check discoveries to the published state and user-initiated checks to the standard driver. Driven by invoking the driver's `show…` methods directly.
- Appcast XML writer script: given a minimal existing feed + a new release, produces the expected output; handles the empty-file seed case; is idempotent on same-version re-run.

**Integration test (manual, documented in `docs/release/README.md`):**
- Build two Graftty versions (`0.0.1` and `0.0.2`) locally with different `GRAFTTY_VERSION`.
- Serve a test `appcast.xml` via `python -m http.server 8000` pointing at the `0.0.2` zip, with a real EdDSA signature.
- Launch `0.0.1` with `SUFeedURL` overridden to `http://localhost:8000/appcast.xml` via a debug build flag.
- Verify: badge appears, click opens Sparkle dialog, "Install Now" quits+replaces+relaunches, relaunched app reports `v0.0.2`.
- Verify zmx: start a long-running command in a pane (`sleep 600`), trigger update, confirm the shell still holds the same PID after relaunch.

## SPECS.md additions

A new top-level `UPDATE-*` section, placed after the release section:

- `UPDATE-1.1` While the user has consented to automatic checks, the application shall query the configured appcast feed once per 24 hours.
- `UPDATE-1.2` When a scheduled check discovers a newer version, the application shall surface a non-modal indicator in the window titlebar (immediately right of the traffic lights) rather than presenting a modal dialog.
- `UPDATE-1.3` When the user clicks the titlebar indicator, the application shall present Sparkle's standard install dialog (Install Now / Install on Quit / Release Notes / Skip This Version).
- `UPDATE-1.4` While no update is available, the application shall hide the titlebar indicator entirely.
- `UPDATE-1.5` When the user selects `Graftty → Check for Updates…`, the application shall perform an immediate check and present Sparkle's standard dialog regardless of whether a newer version exists.
- `UPDATE-1.6` If the user has not yet chosen a preference for automatic checks, on first launch the application shall prompt once and persist the choice.
- `UPDATE-1.7` When an update is installed, the application shall relaunch and restore existing zmx-backed terminal sessions.
- `UPDATE-2.1` When a new version tag is pushed, the release workflow shall generate an EdDSA signature over the release zip, prepend a new entry to `appcast.xml` on `main`, and commit that change with the `graftty-release-bot` identity.
- `UPDATE-2.2` The Homebrew cask shall declare `auto_updates true` so `brew upgrade` does not reinstall a version older than the one Sparkle has applied in-place.

## Tradeoffs

- **Bundle size +~3–5 MB** from `Sparkle.framework`. Acceptable for a developer tool.
- **`raw.githubusercontent.com` is not a CDN.** Soft rate limits exist but won't bite at current scale. Migration to GitHub Pages is a URL swap.
- **Ad-hoc signing today.** Sparkle works with ad-hoc signing (it verifies its own EdDSA signature, separately from codesigning). When the app migrates to Developer ID + notarization, the updater's code does not change.
- **Private key must not be lost.** Losing it forces every user onto a manual-reinstall migration to a new key. Documented in the setup section; the key lives in two places (GitHub Actions secret + developer keychain backup).
- **First `brew install` still runs Sparkle's consent prompt.** Standard macOS UX — users expect it — but slightly redundant with brew having installed the app. Acceptable.

## Out-of-scope follow-ups

- Delta updates (Sparkle supports them; adds complexity to release pipeline).
- Beta channel (appcast structure already allows it).
- GitHub Pages migration (deferred until `raw.githubusercontent.com` becomes a problem).
- Developer ID + notarization migration (orthogonal; updater code unchanged).

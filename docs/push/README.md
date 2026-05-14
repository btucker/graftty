# Push Notifications: Minting and Installing the APNs Auth Key

Push notifications require a `.p8` APNs Auth Key minted from Apple's developer
portal. This is a one-time setup per Graftty release.

## Minting

1. Visit https://developer.apple.com/account/resources/authkeys/list.
2. Click "+" to create a new key.
3. Name it "Graftty APNs" and check **Apple Push Notifications service (APNs)**.
4. Choose **Sandbox & Production** (one key supports both environments).
5. Register, then **download the .p8 immediately** — Apple only allows one download.
6. Note the **Key ID** (e.g. `ABCDE12345`) and your **Team ID** (top-right of the page).

## Installing into the Graftty.app source tree

1. Place the file at `Sources/Graftty/Resources/apns/AuthKey_<KEYID>.p8` (not committed; `.gitignore` excludes `.p8` files in this directory).
2. Add to the macOS app's Info.plist (or however Info.plist keys are configured for this SwiftPM executable target):
   - `APNsKeyID:  <KEYID>`
   - `APNsTeamID: <TEAMID>`
   - `APNsTopic:  com.quotably.graftty`
3. For GrafttyMobile, the same three keys go into `Apps/GrafttyMobile/GrafttyMobile/Info.plist` (template via `Apps/GrafttyMobile/project.yml`).

## End-to-end verification

1. Build Graftty for macOS: `swift build` (and run from Xcode or `.build/debug/Graftty`).
2. Build GrafttyMobile to a real iOS device (iOS simulator does NOT receive APNs pushes). Open `Apps/GrafttyMobile/GrafttyMobile.xcodeproj`, select your device, Cmd-R.
3. Add your Mac as a host in GrafttyMobile, accept the notification prompt.
4. On the Mac, confirm a record appears in `~/Library/Application Support/Graftty/push-devices.json`.
5. Trigger an agent stop (e.g. run `claude` in a Graftty worktree, ask a question, wait for the agent to finish). The macOS banner appears.
6. Lock the Mac (or wait for ≥60s idle). Trigger another agent stop. Within ~5s an iOS banner should appear.
7. Tap the banner → GrafttyMobile opens to the waiting pane.
8. Unlock the Mac, click the macOS banner → the iOS banner disappears.

If the iOS banner never appears, check:
- Console.app filtered by `Graftty` for `ApnsClient` errors.
- The `.p8` file exists at the expected path in the built `.app` (`Graftty.app/Contents/Resources/apns/AuthKey_<KEYID>.p8`).
- iOS Settings → Notifications → Graftty is allowed.

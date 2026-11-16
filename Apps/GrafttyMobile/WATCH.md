# Run Graftty on Apple Watch

1. Install GrafttyMobile on your iPhone and pair a Mac from the Hosts screen.
2. In Hosts, turn on **Enable Apple Watch**. This lets your paired watch view
   requests and send answers while the iPhone app is in the background.
3. Install Graftty on the paired Apple Watch, then open **Needs you**.
4. Select a worktree. Open **Context** for background, choose a suggested answer,
   or use **Your reply** and **Send reply**. The watch shows **Sent to agent**
   after the Mac accepts the answer.
5. Open **View terminal** from a question, or **Terminals** from the inbox to
   browse all running panes, including worktrees without pending questions.

The terminal shows actual rendered text and the last 200 lines of history,
up to 24 KB. Output refreshes every three seconds after the previous request
finishes while the terminal page is active. Scroll with the Digital Crown.
Open the terminal's options to change the font size, turn line wrapping or
follow-output mode off, pause updates, or refresh once. Pausing and turning off
follow-output mode lets you read earlier output without jumping to the bottom.

Terminal viewing is read-only and preserves the host terminal's dimensions.
It does not send keystrokes or take display control. Terminal colors and cursor
animation are not carried in the text view. Update Graftty on the host Mac as
well as the iPhone and watch to use the terminal-reading API.

Use **Refresh** to fetch current requests through the iPhone. If a Mac is
unavailable, its last known requests stay visible and the watch names the
unavailable Mac. Answers are checked against a fresh host snapshot and the
original question. A changed or cleared question cannot receive the old reply.

Permission prompts and their terminal context are visible, but answering a
harness permission prompt requires the terminal on iPhone or Mac. The watch requires a paired,
reachable iPhone; it does not connect directly over watch Wi-Fi or cellular.
Background updates depend on iOS and WatchConnectivity delivery, so they are
not a continuous feed while the iPhone app is suspended.

## Build and inspect the watch app

Use Xcode with the iOS and watchOS SDKs installed. The minimum watch version is
watchOS 10. The watch target uses `GrafttyWatchKit`, which has no terminal,
WebRTC, or SSH dependencies.

```sh
scripts/deps prepare --platforms macos,ios
xcodegen generate --spec Apps/GrafttyMobile/project.yml
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
	-scheme GrafttyWatch -destination 'generic/platform=watchOS Simulator' \
	CODE_SIGNING_ALLOWED=NO build
scripts/swiftpm test --filter WatchInboxTests
```

Build the `GrafttyMobile` scheme to embed the watch app in the phone app. Run
`WatchAttentionProjectionTests` in the iPhone simulator to verify the phone's
question routing and stale-answer checks.

For UI inspection, Debug watch builds accept `--watch-preview` for a synthetic
inbox and `--watch-preview --watch-preview-question` for its first question.
Use `--watch-preview --watch-preview-terminal` to open the terminal viewer directly.
These launch arguments use local sample data, terminal output, and simulated replies.

Watch snapshots fit within a 48 KB payload. If more requests are available than
fit, the watch reports how many remain on the iPhone.

The relay uses [`WCSession` application context and interactive messages](https://developer.apple.com/documentation/watchconnectivity/wcsession).
It closes its host connections when each watch request finishes. Turning off
**Enable Apple Watch** stops active relay connections and sends an empty,
disabled snapshot to the watch.

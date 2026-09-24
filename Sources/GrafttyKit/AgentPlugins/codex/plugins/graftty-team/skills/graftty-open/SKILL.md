---
name: graftty-open
description: Use Graftty Mobile to preview a file or HTTP(S) page from the Mac when the user asks to view it there or wants to inspect a generated artifact on mobile.
---

# Graftty open

Use `graftty open` when the user wants to inspect a host file or web page on Graftty Mobile, including a generated image, HTML page, CSV, or local development site. Offer the finished artifact when it is ready for review. Routine intermediate files do not need an offer.

Run the command from the Mac's tracked worktree whose pane the user will open on mobile. Quote paths and URLs so spaces and shell metacharacters remain literal:

```sh
graftty open './output/chart.png'
graftty open 'http://localhost:3000'
graftty open 'https://example.com/report'
```

Use the Graftty CLI that matches the running app. If `graftty` is absent from `PATH`, locate that app's bundled CLI and check `graftty help open`. An older app build without the `open` subcommand cannot make the offer.

For files, `graftty open` accepts a readable regular file up to 20 MB. It snapshots that one file for 15 minutes. Graftty Mobile uses iOS Quick Look when available and otherwise offers the share sheet. An HTML file does not bring along its linked assets; serve a multi-file site on the Mac and offer its HTTP URL instead.

For URLs, use HTTP or HTTPS without credentials embedded in the URL. The page renders in Graftty Mobile's browser, while its connections and DNS go through the directly paired Mac. This lets `localhost` name a server on the Mac and also works for public sites the Mac can reach. A relay worktree cannot browse these URLs. The mobile browser has its own cookies and login state; `graftty open` does not use the Mac's default browser session. A sign-in flow is suitable only when the user can complete it in that mobile browser.

The command's success means the resource was offered, not that the user opened it. Ask the user to open the same worktree in Graftty Mobile and choose the resource from its Open menu. If the offer expires, run the command again. Report a command error as an error; do not say the preview is ready.

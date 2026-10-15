---
name: graftty-open
description: Open HTTP(S) URLs or files explicitly requested in their default app on the pane leader's device. Use graftty-preview for visual explanations, file previews, and finished review artifacts.
---

# Graftty open

For finished artifacts the user should review, including HTML explanations, images, PDFs, spreadsheets, and presentations, use [graftty-preview](../graftty-preview/SKILL.md) and `graftty preview`. When a visual would explain something better, create self-contained HTML and preview it.

Use `graftty open` for HTTP(S) URLs, including a local development site, or when the user explicitly asks to open a file in its default app. Do not open source files you edited as part of a coding task or routine intermediate files.

Run the command from the Mac's tracked worktree and pane where you are working. Graftty checks that pane's current display leader when the command runs. If Graftty Mobile leads, it offers the resource in that worktree's Open menu for 15 minutes. Otherwise macOS opens it with the default app or browser. Quote paths and URLs so spaces and shell metacharacters remain literal:

```sh
graftty open './output/chart.png'
graftty open 'http://localhost:3000'
graftty open 'https://example.com/report'
```

Use the Graftty CLI that matches the running app. If `graftty` is absent from `PATH`, locate that app's bundled CLI and check `graftty help open`. An older app build without the `open` subcommand cannot make the offer.

For mobile previews, `graftty open` accepts a readable regular file up to 20 MB. It snapshots that one file for 15 minutes. Graftty Mobile uses iOS Quick Look when available and otherwise offers the share sheet. An HTML file does not bring along its linked assets; serve a multi-file site on the Mac and open its HTTP URL instead.

For URLs, use HTTP or HTTPS without credentials embedded in the URL. When mobile leads, the page renders in Graftty Mobile's browser, while its connections and DNS go through the directly paired Mac. This lets `localhost` name a server on the Mac and also works for public sites the Mac can reach. A relay worktree cannot browse these URLs. The mobile browser has its own cookies and login state. When Mac leads, the URL opens in the Mac's default browser, including its existing session.

On mobile, command success means the resource was offered, not that the user opened it. Tell the user to choose it from the Open menu in that worktree if they are on mobile. If the offer expires, run the command again. Report a command error as an error; do not say the preview is ready.

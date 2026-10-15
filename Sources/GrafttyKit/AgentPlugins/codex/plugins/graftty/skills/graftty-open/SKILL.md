---
name: graftty-open
description: Open HTTP(S) URLs or files explicitly requested in their default app on the pane leader's device. Use graftty-preview for visual explanations, file previews, and finished review artifacts.
---

# Graftty open

Use [graftty-preview](../graftty-preview/SKILL.md) for finished artifacts made for review, including self-contained HTML explanations. Use `graftty open` for HTTP(S) URLs, including local development sites, or when the user explicitly asks to open a file in its default app. Source edits and internal files need no preview.

Run from your tracked worktree and pane. Quote paths and URLs:

```sh
graftty open './output/report.pdf'
graftty open 'http://localhost:3000'
```

The current pane leader determines delivery:

- **Mac:** opens with the default app or browser, including its existing session.
- **Graftty Mobile:** offers the resource in that worktree's Open menu for 15 minutes. Files use Quick Look or the share sheet. HTTP(S) pages use Mobile's browser with separate cookies; connections and DNS go through the directly paired Mac, so `localhost` refers to that Mac. Relay worktrees cannot browse URLs.

Mobile accepts one readable regular file up to 20 MB and snapshots it for 15 minutes. Linked HTML assets are not included; serve multi-file sites and open their HTTP URL. URLs must not contain embedded credentials.

On mobile, success means offered, not opened. Point the user to the Open menu; rerun after expiry. Report command errors without claiming the preview is ready.

Use the CLI matching the running app. If absent from PATH, use its bundled helper, such as `/Applications/Graftty.app/Contents/Helpers/graftty`, and check `graftty help open`. An unknown subcommand requires an app update.

For restricted Codex socket access, follow [graftty-team](../graftty-team/SKILL.md) before running the command.

---
name: graftty-preview
description: >-
  Use whenever an explanation would be clearer visually, even when no artifact
  exists yet. Create self-contained HTML and show it with graftty preview.
  Also use when the user asks to see a file, asks to see it again, or you produce
  a finished artifact for review. Use graftty-open for URLs or explicit requests
  to open files in their default app.
---

# Graftty preview

When a visual would explain something better, create self-contained HTML and preview it. Use this for diagrams, comparisons, flows, timelines, layouts, and other explanations that benefit from a visual. Keep short factual answers in chat when a visual adds nothing.

Before responding with a finished artifact for review, run `graftty preview` on its saved file. Do this without waiting for a separate viewing request. A tool image, `view_image`, Markdown embed, or file link alone does not open Graftty's native preview. Ordinary source edits and intermediate files used only for internal inspection do not need a preview.

```sh
graftty preview './output/explanation.html'
graftty preview './output/before.png' './output/after.png' './output/report.pdf'
```

The skill is named `graftty-preview`; the CLI command is `graftty preview`, with a space. `graftty image` remains a compatibility alias. For "show them again", use the existing files rather than regenerating them.

## HTML explanations

Save one HTML file with inline CSS, inline SVG for diagrams, and embedded images when needed. Include a viewport meta tag and use a layout readable on both Mac and phone. Use descriptive labels, enough contrast, and text that explains the visual. Quick Look receives each file separately, so linked assets and sibling files do not travel with HTML.

Make the explanation readable without JavaScript, remote fonts, libraries, or network requests. For a site that needs JavaScript, navigation, or external assets, serve it and use `graftty open 'http://localhost:3000'` instead. Use the task's authoring tools for existing images, documents, or scientific plots; do not convert every artifact to HTML.

## Native preview

On macOS the native tray embeds Quick Look. Drag the header to move it, the bottom edge to change height, or the corner grip to resize. Use the previous and next controls or the file picker to move through a collection. Quick Look owns rendering, pages, zoom, and supported media controls. Open… opens the selected original file in its default app and reports errors in the tray. Close dismisses the tray; Escape dismisses only while the preview owns focus. Arrival preserves terminal focus and does not resize the terminal grid.

On Graftty Mobile, a new preview automatically opens once for the focused owning pane when presentation is available. Another open resource defers it. Closing it does not reopen the same offer. The Preview control reopens the latest collection in native Quick Look with zoom and sharing. Done closes it. Without a supported display leader, the preview is saved for manual worktree browsing. An unrecognized mobile recipient returns an error without publishing the request.

The command accepts 1 to 20 readable regular files, up to 20 MB per file and 50 MB total. Quick Look decides which file types it can render on that device; support can differ between macOS and iOS. Every published collection is retained in the host-owned worktree library and is available from the preview menu on local Mac, paired Mac, iPhone, and iPad clients. Each client chooses what to open. New requests do not change other clients' selections. Automatic mobile delivery expires after 15 minutes; the saved library survives that expiry and host restarts. Snapshots preserve the files as requested. Legacy `--width` and `--pad` options are accepted and ignored.

A quiet zero exit status acknowledges the request. It does not prove that the user saw the files. Keep an artifact link in the response. For images, also use a Markdown image embed:

```markdown
![Chart](./output/chart.png)
![Refined sidebar](</absolute/path with spaces/sidebar.png>)
```

For a Markdown image reference, extract its destination and remove angle brackets or an optional title. Resolve relative paths against the containing Markdown file's directory, or the current worktree for a chat reference. Pass the local path as a quoted argument, not the Markdown expression. Use `graftty open` for remote HTTP(S) URLs.

If `graftty preview` fails, report its actual error and try `graftty open <path>` when a separate native file viewer would help. Do not claim delivery after a failure or a missing preview. If an older CLI lacks the `preview` command, use `graftty image` for images or `graftty open` for other files. If the running app rejects the new preview request, use `graftty open`; the new CLI's `image` alias sends the same request and cannot downgrade it. Locate the bundled CLI as described in [graftty-open](../graftty-open/SKILL.md).

Do not use `imgcat`, `kitten icat`, `chafa`, hand-written graphics escapes, or padding newlines. Never write directly to `/dev/tty*` or send a terminal query from a tool shell.

For restricted Codex socket access, follow [graftty-team](../graftty-team/SKILL.md) before running the command.

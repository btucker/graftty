---
name: graftty-image
description: Show images, screenshots, diagrams, charts, and mockups in Graftty's native preview. Use when the user asks to see them, asks to see them again, or when you produce a finished visual for review without a separate preview request.
---

# Graftty image

Previewing is part of delivering a finished visual. Before responding with a generated image, mockup, screenshot, chart, or diagram for the user's review, run `graftty image` on the saved file. Do this without waiting for a separate "show me" request. A tool's image output, `view_image`, Markdown embed, or file link alone does not open Graftty's native preview.

For "show these", "let me see it", or "show them again", use the existing files and request the native preview again. This skill displays files; use the task's authoring tools to create them. Ordinary source files and intermediate images used only for internal inspection do not need a preview.

Show a file with `graftty image`:

```sh
graftty image './output/chart.png'
```

The skill is named `graftty-image`; the CLI command is `graftty image`, with a space. For several visuals that need to be compared together, use a labeled comparison sheet: each native tray request replaces its previous image.

## Markdown images

Treat a Markdown image such as `![Chart](./output/chart.png)` or `![Sidebar](</path with spaces/sidebar.png>)` as an image reference. Extract the destination, removing Markdown angle brackets and any optional title. Resolve a relative destination against the containing Markdown file's directory, or the current worktree for a chat reference. Pass the resulting local file path to `graftty image` as a quoted argument, not the entire Markdown expression. A remote HTTP(S) image URL can be opened with `graftty open`; do not pass it to `graftty image` as a file path.

When including the preview in an agent response, use a Markdown image embed with descriptive alt text and the actual image path:

```markdown
![Refined sidebar](</absolute/path with spaces/sidebar.png>)
```

This lets chat clients that support Markdown images display it and preserves the reference in the transcript. A plain link, `view_image` tool result, or image-generation tool result alone does not establish that the user can see the image. In a Graftty terminal pane, also run `graftty image`; Markdown text does not replace requesting the native preview. If asked to show an image again, use the existing file rather than regenerating it.

## Native preview

On macOS this requests a native tray sliding down from the top of the terminal area. The focused pane's preview appears without moving the terminal grid or stealing keyboard focus. Background pane requests remain scoped to their originating pane. A new request replaces that pane's previous image. Use Fit to reset, zoom in or out to enlarge, scroll to pan, and Close to dismiss. Drag the header to move the tray within the terminal area, its bottom edge to change height, or its lower-right grip to resize it in both directions. Open… opens the original source file in Preview.app; a missing or moved file produces a visible error in the tray. Escape dismisses only while the preview owns focus. On Graftty Mobile, tap the focused owning pane's Images control to open native Quick Look with zoom and sharing. Image arrival leaves terminal typing unchanged. Unsupported display leaders or unrecognized mobile recipients return an error rather than showing an image on the host Mac.

The command works from a tool shell without a tty. It accepts readable PNG, JPEG, HEIC, GIF, WebP, and PDF files up to 20 MB. The macOS tray previews only the first frame or page and bounds decoded resolution. Mobile receives the original file bytes for native Quick Look. Legacy `--width` and `--pad` flags are accepted and ignored. The preview is temporary; run the command again if asked.

A quiet zero exit status acknowledges the request. It does not prove the user saw the image. Include a Markdown image reference in your final response so the conversation keeps the artifact reference:

```markdown
![Chart](./output/chart.png)
```

Use an absolute path when the relative path would be ambiguous. If `graftty image` fails, report its actual error, keep the Markdown reference, and try `graftty open <path>` when a separate native file viewer would help. Do not claim delivery after a failure. If the command succeeds but the user sees no image, report that result and use the same native fallback. If an older build prints raw image payload such as base64 or escape sequences, or corrupted terminal text, stop inline retries. Do not infer a Codex or terminal limitation from the exit status alone.

Use only `graftty image` for the native tray. Do not use `imgcat`, `kitten icat`, `chafa`, hand-written Kitty graphics escapes, or padding newlines. Never write to `/dev/tty*` directly and never send a terminal query from a tool shell. Terminal graphics can print raw payloads or cover transcript text.

Locate the CLI as described in the graftty-open skill. If the app reports an unknown command or request, its build is too old for the tray. Report that result and use the fallback above.

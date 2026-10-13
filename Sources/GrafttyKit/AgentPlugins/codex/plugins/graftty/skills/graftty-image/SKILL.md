---
name: graftty-image
description: Use when the user asks to see, show, display, preview, or render an image, screenshot, diagram, chart, or photo in Graftty, or when a finished image should be shown alongside an agent response.
---

# Graftty image

Show a file with `graftty image`:

```sh
graftty image './output/chart.png'
```

On macOS this requests a native tray sliding down from the top of the terminal area. The focused pane's preview appears without moving the terminal grid or stealing keyboard focus. Background pane requests remain scoped to their originating pane. A new request replaces that pane's previous image. Use Fit to reset, zoom in or out to enlarge, scroll to pan, and Close to dismiss. Escape dismisses only while the preview owns focus. Graftty Mobile uses the existing native preview offer on the pane leader. Unsupported display leaders return an error rather than showing an image on the host Mac.

The command works from a tool shell without a tty. It accepts readable PNG, JPEG, HEIC, GIF, WebP, and PDF files up to 20 MB, previews only the first frame or page, and bounds decoded resolution. Legacy `--width` and `--pad` flags are accepted and ignored. The preview is temporary; run the command again if asked.

A quiet zero exit status acknowledges the request. It does not prove the user saw the image. Include a Markdown image reference in your final response so the conversation keeps the artifact reference:

```markdown
![Chart](./output/chart.png)
```

Use an absolute path when the relative path would be ambiguous. If `graftty image` fails, report its actual error, keep the Markdown reference, and try `graftty open <path>` when a separate native file viewer would help. Do not claim delivery after a failure.

Use only `graftty image` for the native tray. Do not use `imgcat`, `kitten icat`, `chafa`, hand-written Kitty graphics escapes, or padding newlines. Never write to `/dev/tty*` directly and never send a terminal query from a tool shell. Terminal graphics can print raw payloads or cover transcript text.

Locate the CLI as described in the graftty-open skill. If the app reports an unknown command or request, its build is too old for the tray. Report that result and use the fallback above.

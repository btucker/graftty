---
name: graftty-image
description: Show requested images or finished review visuals in Graftty's native preview, including requests to show them again.
---

# Graftty image

Before responding with a finished review visual, run `graftty image` on its saved file. Do this without a separate preview request. Tool images, `view_image`, Markdown, and file links alone do not open the native preview. Internal inspection images need no preview.

```sh
graftty image './output/chart.png'
```

For requests to show an image again, reuse the existing file. For several visuals that must be compared together, make a labeled comparison sheet: each request replaces that pane's previous image.

## Resolve image references

For Markdown such as `![Chart](./output/chart.png)` or `![Sidebar](</path with spaces/sidebar.png>)`, extract the destination without angle brackets or an optional title. Resolve relative paths against the containing Markdown file's directory, or the current worktree for chat references. Pass the quoted local path to `graftty image`, not the Markdown expression. Open remote HTTP(S) image URLs with `graftty open`.

Include a descriptive Markdown image embed in the final response to preserve the artifact reference:

```markdown
![Chart](</absolute/path with spaces/chart.png>)
```

## Delivery and failures

The command works from tool shells without a tty and accepts readable PNG, JPEG, HEIC, GIF, WebP, and PDF files up to 20 MB. The native tray stays scoped to the originating pane and leaves terminal typing unchanged. Mobile uses the focused owning pane's Images control for Quick Look. Read [preview controls](references/preview-controls.md) when explaining controls, frame limits, or legacy flags.

A quiet zero exit acknowledges the request, not that the user saw it. On error, or success without a visible preview, report the actual result, keep the Markdown reference, and try `graftty open <path>` when a separate viewer would help. An unknown command or request indicates an older app build. Stop inline retries if output contains raw payload or corrupted terminal text.

Use only `graftty image` for the native preview. Do not use `imgcat`, `kitten icat`, `chafa`, handwritten graphics escapes, or padding newlines. Never write directly to `/dev/tty*` or send a terminal query from a tool shell.

Use the matching app's helper if the CLI is absent from PATH, as [graftty-open](../graftty-open/SKILL.md) describes. For restricted Codex socket access, follow [graftty-team](../graftty-team/SKILL.md) before running the command.

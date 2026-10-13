---
name: graftty-image
description: Use when the user asks to see, show, display, preview, or render an image, screenshot, diagram, chart, or photo, including Markdown image references, or when a finished image should be shown in place in the pane. Also use before reaching for imgcat, kitten icat, chafa, or hand-written Kitty graphics escapes.
---

# Graftty image

Run `graftty image` to draw an image file inline in the current Graftty pane:

```sh
graftty image './output/chart.png'
```

## Markdown images

Treat a Markdown image such as `![Chart](./output/chart.png)` or `![Sidebar](</path with spaces/sidebar.png>)` as an image reference. Extract the destination, removing Markdown angle brackets and any optional title. Resolve a relative destination against the containing Markdown file's directory, or the current worktree for a chat reference. Pass the resulting local file path to `graftty image` as a quoted argument, not the entire Markdown expression. A remote HTTP(S) image URL can be opened with `graftty open`; do not pass it to `graftty image` as a file path.

When including the preview in an agent response, use a Markdown image embed with descriptive alt text and the actual image path:

```markdown
![Refined sidebar](</absolute/path with spaces/sidebar.png>)
```

This lets chat clients that support Markdown images display it and preserves the reference in the transcript. A plain link, `view_image` tool result, or image-generation tool result alone does not establish that the user can see the image. In a Graftty terminal pane, also run `graftty image`; Markdown text does not replace drawing the image. If asked to show an image again, use the existing file rather than regenerating it.

## Terminal display

It works from an agent tool shell that has no tty of its own, scales the image to the pane width, and reserves blank padding rows below the image so a TUI such as Claude Code or Codex repaints only the padding. On success it prints `Drew <name> at <cols>x<rows> cells.`; relay that line and tell the user the image sits above the current prompt and scrolls with the transcript. If the user reports text overlapping the image's bottom edge, redraw with a larger `--pad`. See `graftty help image` for the accepted formats and flags.

Draw images in a Graftty pane only with this command. `imgcat` speaks the iTerm2 protocol, which ghostty does not implement. `kitten icat`, `chafa`, and hand-written `ESC _ G` escapes place the image at the cursor or at an absolute row with no padding, so the TUI repaints over it or the image covers transcript text. Never write to `/dev/tty*` devices directly, and never send a terminal query from a tool shell: the reply lands in the TUI's input.

If `graftty image` exits nonzero, report its message and fall back to `graftty open <path>`, which shows the file on the pane leader's device. Inline images draw on whichever device leads the pane, including Graftty Mobile. If `graftty image` reports that the pane did not report pixel geometry, the leading client does not report it (a web browser or an older app), so fall back to `graftty open`. Images are not restored after a pane reattaches; run the command again if asked.

Locate the CLI as described in the graftty-open skill. If `graftty help image` reports no such subcommand, the app build is too old to draw inline; use `graftty open`.

---
name: graftty-image
description: Use when the user asks to see, show, display, preview, or render an image, screenshot, diagram, chart, or photo inline in the terminal pane, or when a finished image should be shown in place in the pane. Also use before reaching for imgcat, kitten icat, chafa, or hand-written Kitty graphics escapes.
---

# Graftty image

Run `graftty image` to draw an image file inline in the current Graftty pane:

```sh
graftty image './output/chart.png'
```

It works from an agent tool shell that has no tty of its own, scales the image to the pane width, and reserves blank padding rows below the image so a TUI such as Claude Code or Codex repaints only the padding. On success it prints `Drew <name> at <cols>x<rows> cells.`; relay that line and tell the user the image sits above the current prompt and scrolls with the transcript. If the user reports text overlapping the image's bottom edge, redraw with a larger `--pad`. See `graftty help image` for the accepted formats and flags.

Draw images in a Graftty pane only with this command. `imgcat` speaks the iTerm2 protocol, which ghostty does not implement. `kitten icat`, `chafa`, and hand-written `ESC _ G` escapes place the image at the cursor or at an absolute row with no padding, so the TUI repaints over it or the image covers transcript text. Never write to `/dev/tty*` devices directly, and never send a terminal query from a tool shell: the reply lands in the TUI's input.

If `graftty image` exits nonzero, report its message and fall back to `graftty open <path>`, which shows the file on the pane leader's device. Inline images draw on whichever device leads the pane, including Graftty Mobile. If `graftty image` reports that the pane did not report pixel geometry, the leading client does not report it (a web browser or an older app), so fall back to `graftty open`. Images are not restored after a pane reattaches; run the command again if asked.

Locate the CLI as described in the graftty-open skill. If `graftty help image` reports no such subcommand, the app build is too old to draw inline; use `graftty open`.

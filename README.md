<p align="center">
  <img src="Resources/AppIcon.png" alt="Graftty app icon" width="128" />
</p>

# Graftty

A macOS worktree-aware terminal multiplexer built on [libghostty](https://ghostty.org) & [zmx.sh](https://zmx.sh/).

Graftty organizes persistent terminal sessions by git worktree. Each worktree in your sidebar has its own split layout of terminals that stay alive across worktree switches, and a CLI (`graftty`) lets running processes interact with the Graftty UI.

<p align="center">
  <img src="docs/screenshot.png" alt="Graftty showing a worktree sidebar and split terminal layout" width="900" />
</p>

## Installing

```sh
brew tap btucker/graftty
brew install --cask graftty
```

Installs `Graftty.app` to `/Applications` and symlinks the `graftty` CLI onto `PATH`. On first launch, macOS will block the app with Gatekeeper — approve it under System Settings → Privacy & Security (on Sonoma, right-click → Open). Uninstall with `brew uninstall --cask --zap graftty`.

Graftty updates itself. On first launch, you'll be asked whether
Graftty may check for updates automatically — if you agree, a small
indicator appears in the window titlebar when a new version is
available, and clicking it installs the update. You can also trigger a
check manually from `Graftty → Check for Updates…`.

## CLI

The bundled `graftty` CLI lets a process inside a Graftty pane drive the app, and lets one agent control panes in another worktree.

```sh
graftty notify "tests passing"               # set a sidebar attention badge
graftty pane list                            # panes in the current worktree
graftty pane add --command "claude"          # split + run a command
graftty pane close 2                         # close pane 2

# Cross-worktree pane control:
graftty pane list drag-files                 # list panes in another worktree
graftty pane show drag-files:1               # last 100 lines of that pane's output
graftty pane show drag-files:1 --lines 500   # more scrollback
graftty pane send drag-files:1 "pnpm test"   # type the command and press Enter
graftty pane send drag-files:1 "y" --no-enter  # type without committing

# Team coordination across worktrees:
graftty team list                            # registered teammates
graftty team send drag-files "ready"         # cooperative inbox message
```

`<addr>` is `<id>` (current worktree, that pane), `<worktree>` (worktree's only pane), or `<worktree>:<id>`. Worktree names match what `graftty team list` prints. Run `graftty pane <verb> --help` for examples on every subcommand.

`graftty pane send` writes raw bytes to the addressed pane's PTY — there's no inbox or consent layer, so the keystrokes land in whatever process is reading that pane's stdin. Use `graftty team send` for cooperative messaging where the receiving agent decides what to do.

## Building

Requires Xcode 15+ and macOS 14 Sonoma or later.

```sh
swift build
```

Open `Package.swift` in Xcode to run the app.

## Developing the web client

Graftty's browser-facing web access client lives in `web-client/` (React +
Vite + TypeScript + TanStack Router). If you change anything under
`web-client/`, rebuild the bundle that ships with the app:

```bash
./scripts/build-web.sh
```

This refreshes `Sources/GrafttyKit/Web/Resources/{index.html,app.js,app.css}`.
CI verifies the committed bundle matches a fresh build.

You need `node` (LTS) and `pnpm` installed locally for web-client work:

```bash
brew install node pnpm
```

If you only touch Swift, you need neither — the committed bundle is what
`swift build` ships, and Homebrew users get the prebuilt tarball.

## Further reading

- [`SPECS.md`](SPECS.md) — authoritative EARS-style behavior spec.
- [`docs/`](docs) — design notes and architecture details.

## License

MIT — see [`LICENSE`](LICENSE).

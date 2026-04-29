# Cmd-click to open files in `$EDITOR`

**Date:** 2026-04-29
**Status:** Approved

## Problem

Cmd-clicking a file path in a terminal pane currently shows a system dialog
"The application can't be opened. -50". libghostty detects the path and fires
`GHOSTTY_ACTION_OPEN_URL` with `kind: .unknown` and a *schemeless* URL string
(e.g. `Sources/Foo.swift:42:1`); Graftty's handler at
`Sources/Graftty/Terminal/TerminalManager.swift:709–716` calls
`NSWorkspace.shared.open(URL(string: rawString))` which parses but has no
scheme LaunchServices can dispatch — hence the dialog.

The right behavior is: open the path in the user's editor. If the editor is a
GUI app, dispatch via NSWorkspace. If it's a CLI editor like `nvim`, open it
in a new pane split right of the source pane (cmd+D direction), so the editor
runs against a real PTY in the same tab.

## Change

Replace the schemeless `NSWorkspace.shared.open` line with an editor router
that classifies the URL, resolves paths against the source pane's PWD, and
dispatches to either a new split pane (CLI) or `NSWorkspace.openApplication`
(GUI). Add a Settings UI for picking the editor. Non-file URLs (http(s),
mailto:, ssh:, etc.) keep their existing `NSWorkspace.shared.open` path.

## libghostty behavior we rely on (already correct)

Verified against `ghostty-org/ghostty@HEAD`:

- **Default `link-url` regex** (`src/config/url.zig`) catches scheme URLs,
  rooted paths (`/`, `~/`, `./`, `../`, `$VAR/`), and bare relative paths
  (`src/foo.swift`). Matches iTerm2's detection plus more.
- **OSC 8 hyperlinks** dispatch through the same `OPEN_URL` action with the
  OSC 8 URI as the URL string — including `file://` URIs. No special handling
  needed on Graftty's side.
- **Path resolution** (`Surface.zig::resolvePathForOpening`) tries to resolve
  relative paths against the terminal's OSC 7 PWD and substitute the
  absolute path *only if the resolved file exists*. With a `:line:col`
  suffix glued on, that check fails, so we receive the raw matched string —
  which is why our own router has to strip `:line(:col)` and re-resolve.
- **Action `kind`** is `.unknown` for both regex-matched and OSC 8 clicks
  (`Surface.zig:4385–4397`); `.text`/`.html` are reserved for internally
  triggered "open" actions. We don't switch on `kind`.

We do **not** inject a custom `link-url` config; Ghostty's default already
covers everything we need.

## Components

All new code lives in `Sources/GrafttyKit/Editor/` and is pure logic — no
AppKit, no `TerminalManager`, no `AppState`. UI glue lives in `Sources/Graftty/`.

### `EditorOpenRouter` (logic)

```
classify(urlString:paneCwd:fileExistsCheck:) -> ClassifiedTarget
  .editorOpen(absolutePath: URL, line: Int?, column: Int?)
  .browser(URL)
  .invalid

resolve(target: ClassifiedTarget, editor: ResolvedEditor) -> EditorAction
  .openInPane(initialInput: String)
  .openWithApp(file: URL, app: URL)
  .openInBrowser(URL)
```

`classify` rules, in order:

1. `URL(string:)` parse. Scheme is non-`file` and non-empty → `.browser`.
2. `file://` scheme → unwrap to filesystem path, continue at step 4.
3. No scheme → treat the whole string as a candidate path, continue at step 4.
4. Resolve the raw candidate relative to `paneCwd` if not absolute; expand
   leading `~`. Run `fileExistsCheck` — if it exists, return `.editorOpen`
   with `line=nil, column=nil`. (This branch handles filenames that
   literally contain `:NN`.)
5. Otherwise, attempt to strip an optional `:line(:col)` suffix using
   `^(.+?)(?::(\d+)(?::(\d+))?)?$`. If a suffix was captured, resolve the
   shorter path the same way and re-check existence — if it exists, return
   `.editorOpen` with the captured line/column.
6. Both checks failed → `.invalid`.

### `EditorPreference` (logic)

Layered lookup, returns a `ResolvedEditor` with kind + source:

1. Graftty `UserDefaults` (`editorKind` ∈ `{"app", "cli"}` — empty falls through).
2. Cached shell `$EDITOR`, captured at app startup via
   `$SHELL -ilc 'echo "$EDITOR"'` — interactive login shell sources rc files.
3. `vi` (always present on macOS).

`source` is captured (`.userPreference | .shellEnv | .defaultFallback`) so
the Settings pane can show what's actually being used and tests can assert
which branch fired.

If `editorKind == "app"` but `editorAppBundleID` is empty (user picked App
but never selected one) or `editorKind == "cli"` with empty
`editorCliCommand`, treat that layer as unset and fall through to the
shell-`$EDITOR` layer. The Settings UI also disables the radio toggle for
those rows until the dependent field has a value, so this fallback is
defensive rather than the common path.

`ShellEnvProbe` is the dependency for step 2; injected so unit tests don't
spawn shells.

### CLI vs GUI classification

When the source is `.userPreference`, the user explicitly picked a kind;
the router obeys it. When the source is `.shellEnv`, the entire `$EDITOR`
value is treated as a CLI command (which is what `$EDITOR` means by
convention).

A small known-CLI allow-list (`vi`, `vim`, `nvim`, `nano`, `helix`/`hx`,
`emacs -nw`, `micro`, `kak`) is used only to decide whether to append the
`+<line>` flag for line navigation. Editors not on the list still launch,
just without the line flag.

### CLI launch command

```
"<editor> <quoted-path><line-flag>\n"
```

- Path quoted in single quotes with `'\''` escaping.
- Line flag is `+<N>` for everything on the allow-list (POSIX-standard;
  vi/vim/nvim/helix/nano/emacs -nw/micro/kak all support it).
- **Column is dropped** in v1 — known limitation, no portable CLI
  convention exists.
- Trailing `\n` triggers immediate execution at the shell prompt.

### Pane spawn

`splitPane` in `Sources/Graftty/GrafttyApp.swift` gains an optional
parameter, defaulting to `nil` so existing call sites are unchanged:

```swift
fileprivate static func splitPane(
    appState: Binding<AppState>,
    terminalManager: TerminalManager,
    targetID: TerminalID,
    split: PaneSplit,
    extraInitialInput: String? = nil
) -> TerminalID?
```

`extraInitialInput` threads through `TerminalManager.createSurface` →
`SurfaceHandle.init`, **appended** after the existing `zmxInitialInput`. The
resulting pane is a normal restorable zmx-attached shell that runs the
editor command once after attach.

`TerminalManager` exposes a new callback paralleling `onSplitRequest`:

```swift
var onOpenInEditorPane: ((TerminalID, String) -> Void)?  // sourceID, command
```

`GrafttyApp` wires it to call `splitPane(targetID:, split: .right, extraInitialInput: command + "\n")`.

### GUI launch

```swift
NSWorkspace.shared.openApplication(
    at: appBundleURL,
    configuration: { promptsUserIfNeeded: false; .openURLs: [fileURL] },
    completionHandler: { _, _ in }
)
```

Line/column information is dropped for GUI editors in v1 — known limitation.
Each app has its own scheme/CLI shim convention (`vscode://file/path:N:M`,
`code -g file:N:M`, etc.); supporting them is per-app branching that's
better as a follow-up after we have the v1 routing in place.

## Settings UI

Three new keys in `Sources/Graftty/Channels/SettingsKeys.swift`:

```swift
static let editorKind        = "editorKind"        // "" | "app" | "cli"
static let editorAppBundleID = "editorAppBundleID"
static let editorCliCommand  = "editorCliCommand"
```

Empty `editorKind` is the sane default — falls through to shell `$EDITOR`.

A new "Editor" section in `Sources/Graftty/Views/SettingsView.swift`
(rendered below "Default command" / "Run in first pane only", separated by
the existing `Divider` pattern). A radio group binds to `editorKind`:

```
Editor
  ◯ Use $EDITOR from shell  (current: nvim)
  ◯ App:  [Cursor              ▾]
  ◯ CLI:  [nvim                  ]

  Used when you cmd-click a file path in a pane.
```

The first row's caption shows the resolved value from `EditorPreference`.
The non-selected rows' picker / text field is greyed out (matches macOS
network preferences UX).

The App picker is populated via:

```swift
NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: "/tmp/x.txt"))
```

Deduped by bundle ID, sorted by display name, each row showing icon + name.
The selected row's bundle ID is what gets stored — apps move, but bundle
IDs are stable.

The CLI field is a plain `TextField` with prompt `"e.g., nvim"`. Free-form;
no validation on save. Tokenized on whitespace at launch.

## Files touched

**New:**
- `Sources/GrafttyKit/Editor/EditorOpenRouter.swift`
- `Sources/GrafttyKit/Editor/EditorPreference.swift`
- `Sources/GrafttyKit/Editor/ShellEnvProbe.swift`
- `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`
- `Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift`

**Modified:**
- `Sources/Graftty/Terminal/TerminalManager.swift` — replace the
  `GHOSTTY_ACTION_OPEN_URL` handler body (lines 709–716) with a router call;
  add `onOpenInEditorPane` callback.
- `Sources/Graftty/GrafttyApp.swift` — add `extraInitialInput` parameter to
  `splitPane`; wire `onOpenInEditorPane` to it; capture shell `$EDITOR` at
  startup and inject into `EditorPreference`.
- `Sources/Graftty/Terminal/SurfaceHandle.swift` — accept optional
  `extraInitialInput` parameter, sent after `zmxInitialInput` so the editor
  command runs once the zmx-attached shell is ready.
- `Sources/Graftty/Views/SettingsView.swift` — add the Editor section.
- `Sources/Graftty/Channels/SettingsKeys.swift` — add the three keys.
- `SPECS.md` — add new `Editor` section with `EDITOR-1.x` requirements.

## SPECS.md additions

New top-level `Editor` section (placement: after the Terminal-pane sections,
before unrelated chrome sections — exact neighbor chosen at write time).

```
EDITOR-1.1  When the user cmd-clicks a file path in a terminal pane, the
            application shall open the file via the configured editor.

EDITOR-1.2  If the configured editor is a known CLI editor, the application
            shall split the source pane to the right and run the editor in
            the new pane.

EDITOR-1.3  If the configured editor is a GUI app, the application shall
            dispatch the file to the app via NSWorkspace, without creating
            a new pane.

EDITOR-1.4  If the cmd-clicked target carries a `:line(:col)` suffix, the
            application shall strip the suffix before resolving the path,
            and shall pass the line number to known CLI editors using
            `+<line>`.

EDITOR-1.5  If the cmd-clicked target is not a file path, the application
            shall open it via NSWorkspace (preserving existing handling for
            http(s), mailto:, ssh:, and other URL schemes).

EDITOR-1.6  If the cmd-clicked target resolves to a path that does not
            exist on disk, the application shall emit a system beep and
            not open anything.

EDITOR-1.7  When no editor is explicitly configured in Settings, the
            application shall use the value of `$EDITOR` as defined by the
            user's login shell.

EDITOR-1.8  If `$EDITOR` is unset, the application shall fall back to `vi`.
```

## Tests

### `EditorOpenRouterTests.swift`

Pure logic, no AppKit. Covers:

- `classify` table: `https://x.com` → browser; `file:///etc/hosts` →
  editorOpen; `Sources/Foo.swift:42:1` → editorOpen with line=42; `/abs/notes.md`
  → editorOpen no line; `garbage::` → invalid; relative path that doesn't
  exist → invalid; `~/x.txt` tilde expansion; `path:42` line only;
  `path:42:5` line+col (col captured but unused per CLI launch).
- `buildCliCommand`: shell-quoting (paths with spaces, `'`, `$`); line
  flag presence per allow-list editor; unknown CLI → no flag; `emacs -nw`
  preserves the `-nw` arg.
- `resolve`: app kind → `.openWithApp`; cli kind → `.openInPane` with
  built command; browser → `.openInBrowser`.

**Bug-reproducing test** (per the user's `~/.claude/CLAUDE.md` rule about
writing failing tests for discovered bugs):
`test_schemelessPath_doesNotProduceBrowserDispatch` — given a schemeless
raw path, classify must return `.editorOpen`, never `.browser`. Reproduces
the "-50 dialog" bug behavior at the routing layer.

### `EditorPreferenceTests.swift`

Uses an injectable `ShellEnvProbe` mock + injected `UserDefaults` (existing
pattern in this repo per `WebAccessSettings`):

- User setting wins over shell env.
- Empty user setting → shell env wins.
- Shell env empty → falls through to `vi` default.
- `source` field correctly identifies which branch fired.

### Manual smoke

The Settings pane renders, the App picker populates, selecting "CLI" reveals
the text field. No automated UI test — Graftty has no snapshot harness.

## What is deliberately NOT changing

- **No custom `link-url` regex injection.** Ghostty's default already
  catches what we need. Adding our own would duplicate work and risk
  divergence from upstream improvements.
- **No Graftty-side cell-under-cursor regex.** We trust the libghostty event
  stream; adding parallel detection would double the surface area.
- **No per-pane `proc_pidinfo` env readback.** App-wide shell `$EDITOR` cache
  covers the 99% case; per-pane override is a future enhancement.
- **No column-number support.** Line numbers cover the meaningful CLI cases;
  CLI editors don't have a portable column flag.
- **No GUI editor line-jumping.** Each app needs its own URL scheme or CLI
  shim; better as a per-app follow-up.
- **No `Open With…` chooser menu.** Single-default-editor is YAGNI-correct
  for v1. A right-click menu can come later if anyone asks.
- **No new context-menu item.** Cmd-click is the entire UI affordance for v1;
  a "Open in Editor" right-click action is a future enhancement.

## Risks

- **Shell env capture timing.** `$SHELL -ilc 'echo "$EDITOR"'` runs an
  interactive login shell, which can take 100–500ms on slow rc files. We
  do this once at app startup on a background queue and cache; the result
  arrives before the user's first cmd-click in practice. If it doesn't, the
  router falls through to `vi` until the cache populates.
- **Bundle ID drift.** A user could pick "Cursor" today and uninstall it
  tomorrow; on next cmd-click the GUI dispatch fails. We surface that via
  `NSWorkspace.openApplication`'s completion handler — log + beep, no dialog.
- **OSC 8 with non-`file` schemes.** OSC 8 lets terminals emit arbitrary
  URIs. We treat the URI through the same classifier, so an OSC 8 link of
  `https://...` correctly routes to the browser. Only `file://` OSC 8 links
  go to the editor.
- **Path with literal `:NN` in the filename.** The line-strip regex will
  incorrectly strip a real colon-numeric suffix from a filename like
  `weird:42`. We re-check existence after the strip — if `weird` exists
  and `weird:42` doesn't, we open `weird` at line 42, which is wrong. The
  inverse risk (existing `weird:42`, no `weird`) we can't even detect
  without the user-typed line number being bogus. v1 ships the simple
  rule; if anyone reports it, we can prefer-existence-of-suffixed-path
  in a follow-up.

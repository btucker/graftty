# iPad Layout M5 — Manual Smoke Checklist

Pre-merge device verification for the M5 sidebar layout. Run on a real
iPad in regular width (landscape, or split-view at half+ the screen).

## 1. Sidebar + detail at regular width

- [ ] App opens with a sidebar visible on the left and detail on the right.
- [ ] Sidebar shows a host header at top, worktree list below.
- [ ] Detail shows `ContentUnavailableView("Pick a worktree")` until a row is tapped.

## 2. Host selection

- [ ] Add a host via the host header's chevron → popover → "+".
- [ ] Tap the header chevron → popover shows the host list with "+" toolbar.
- [ ] Tap a different host → sidebar reloads with its worktrees; selection clears.
- [ ] After relaunch, the last-selected host is restored.

## 3. Worktree selection + pane focus

- [ ] Tap a worktree row → detail shows the focused pane fullscreen.
- [ ] Tap a pane child row (↳) → detail switches to that pane.
- [ ] Tap a non-running worktree → no-op (in-flight rows aren't tappable).
- [ ] Tap a different worktree → detail switches to its focused pane.
- [ ] Delete the currently-selected worktree → detail clears to "Pick a worktree".

## 4. Sidebar resize

- [ ] Drag the column divider → sidebar resizes between 220-480pt.
- [ ] Width persists across relaunch.

## 5. Theme tinting

- [ ] Host with a dark Ghostty theme → sidebar background is a lighter shade.
- [ ] Host with a light Ghostty theme → sidebar background is a darker shade.
- [ ] Switching hosts updates the tint within ~1 second.

## 6. Compact-width fallback

- [ ] Slide the app into Split View at minimum width (compact) → existing iPhone NavigationStack flow takes over.
- [ ] No crash, no UI break when transitioning regular → compact and back.

## 7. Lock overlay

- [ ] Background the app, then foreground → biometric prompt appears.
- [ ] Lock overlay covers both compact and regular layouts; underneath, sidebar/detail are obscured.

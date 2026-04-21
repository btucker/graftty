# wterm Adoption — Web UI Design Specification

Replace xterm.js in Graftty's web access client with [wterm](https://github.com/vercel-labs/wterm), Vercel Labs' DOM-rendering, WASM-core terminal emulator (Apache-2.0). Introduce a React + Vite + TypeScript build pipeline in a new `web-client/` workspace with TanStack Router for client-side routing. The Swift server side is essentially unchanged (small asset-table edit, MIME-map edit, and a URL-composer update to emit path-based session URLs).

## Motivation

The Phase 2 Web Access feature shipped with xterm.js. xterm.js renders to a `<canvas>`, which fights the platform on text selection, browser find, and screen-reader accessibility. wterm renders to the DOM with native selection, clipboard, browser find, alternate-screen-buffer support, and CSS-custom-property themes. Its Zig→WASM core is ~12 KB.

Beyond the immediate UX wins, wterm has a first-class React package (`@wterm/react`) with a `useTerminal` hook. The Phase 2 spec names a future "Phase 3" client built on TanStack Router. Adopting wterm now — together with the React + Vite + TanStack Router toolchain it implies — puts that foundation in place so Phase 3 sub-projects (server-side session API, sidebar mirror, split layout, mobile polish) can each ship as a cheap addition rather than a toolchain introduction.

We specifically adopt **TanStack Router** (client-only), not **TanStack Start** (full-stack framework). Start's value props — SSR, server routes, file-based server loaders — assume a Node runtime, which would duplicate or rewrite the Phase 2 Swift + swift-nio server. The router alone is ~15 KB and gives us type-safe, path-based routes (`/session/$name`) without committing to a Node backend.

This spec scopes **one sub-project** out of that larger Phase 3 work: the frontend swap itself. No new Swift surfaces. No new protocol bytes. No new auth posture. A focused refactor PR.

## Goal

After this PR lands:

- The browser pane is rendered by wterm. A phone long-press on terminal output produces a native iOS text-selection handle, not a canvas-rendered pseudo-selection.
- Graftty ships a React + Vite + TypeScript + TanStack Router workspace at `web-client/`. Any future web-UI work composes React components and adds routes instead of introducing a routing library.
- The browser URL for a session is `/session/<name>` (path-based, router-owned). The old `/?session=<name>` form remains supported via a redirect at the root route, so any in-the-wild bookmarks keep working.
- The WebSocket protocol is byte-for-byte unchanged: binary frames carry PTY bytes, text frames carry the `{"type":"resize",…}` envelope.
- Developers who touch only Swift are unaffected — the built JS bundle is committed to `Sources/GrafttyKit/Web/Resources/`, and `swift build` alone works.
- Developers who touch the web client run `./scripts/build-web.sh` to refresh the committed bundle. CI enforces that the committed bundle matches a fresh build.

## Non-Goals

- No **TanStack Start**, no SSR, no server-side routes, no server-side data loaders. The router is client-only.
- No session list view, no sidebar mirror, no multi-pane split rendering. Those are separate Phase 3 sub-projects that reuse this spec's scaffolding.
- No new HTTP endpoints, no new WS envelope shapes, no allowlist extension to the WhoIs gate. The server's public contract is unchanged.
- No frontend tests. The existing server-side integration test `attachesAndEchoes` proves bytes round-trip; that's sufficient for a refactor with no new logic.
- No CDN imports; wterm's runtime is vendored. The whole point of Tailscale-only binding is that the Mac is reachable without public internet, and so is the client.

## Architecture

```
Repository layout
─────────────────

  web-client/                      ← NEW workspace
    package.json                     pnpm-managed
    pnpm-lock.yaml
    vite.config.ts                   fixed output filenames, no hashes
    tsconfig.json
    src/
      main.tsx                       React root, mounts RouterProvider
      router.tsx                     TanStack Router setup + route tree
      routes/
        __root.tsx                   root layout (status chrome only)
        index.tsx                    "/" → redirect to /session/$name if ?session= present
        session.$name.tsx            "/session/$name" → terminal page
      components/
        TerminalPane.tsx             useTerminal + WS plumbing + resize
      styles.css                     page chrome + CSS-custom-property theme

  scripts/
    build-web.sh                   ← NEW
                                     pnpm install --frozen-lockfile
                                     pnpm build
                                     copy dist into Resources/

  Sources/GrafttyKit/Web/Resources/
    index.html                       ← REPLACED (Vite-generated)
    app.js                           ← REPLACED (React + @wterm/react bundle)
    app.css                          ← REPLACED
    wterm.wasm                       ← NEW
    VERSION                          ← updated (wterm version + git SHA)
    LICENSE-wterm                    ← NEW (Apache-2.0 text)
    NOTICE-wterm                     ← NEW iff upstream ships a NOTICE file
    ── REMOVED ──
    xterm.min.js
    xterm.min.css
    xterm-addon-fit.min.js
```

The Swift server's public contract — `GET /`, `GET /<asset>`, `/ws?session=<name>` upgrade, owner-only `WhoIs` gate, Tailscale-IP + loopback binding — is unchanged. The only Swift code touched is:

- `Sources/GrafttyKit/Web/WebStaticResources.swift` — asset-table entries and a new extension-to-MIME map that includes `application/wasm`.
- `Sources/GrafttyKit/Web/WebServer.swift` — conditional addition of `Cross-Origin-Opener-Policy` + `Cross-Origin-Embedder-Policy` response headers **only if** wterm requires cross-origin isolation; verified at implementation time (see §Error Handling).

## Components

### New — `web-client/` workspace

Lives at repo root next to `Sources/`, `Tests/`, `Resources/`, `docs/`, `scripts/`. It's not a Swift package — it's a pnpm workspace whose build output is copied into the GrafttyKit target's Resources.

- **`package.json`** — declares dependencies (`react`, `react-dom`, `@wterm/react`, `@tanstack/react-router`) and dev-dependencies (`vite`, `@vitejs/plugin-react`, `typescript`, `@types/react`, `@types/react-dom`). One script: `"build": "vite build"`. Uses `"type": "module"`.
- **`pnpm-lock.yaml`** — committed. `build-web.sh` uses `--frozen-lockfile` so CI builds exactly what the developer built.
- **`vite.config.ts`** — production-only config. Key options:
  - `base: './'` — relative asset paths so the built `index.html` works when served at any root.
  - `build.rollupOptions.output.entryFileNames: 'app.js'`, `chunkFileNames: 'chunk-[name].js'`, `assetFileNames: (info) => info.name ?? 'asset'` — no content hashes. The Graftty web server is ephemeral and bound to a user-visible port; cache-busting isn't needed and predictable filenames let `WebStaticResources.asset(for:)` stay a trivial static map.
  - `build.outDir: '../dist-tmp'` — outside the workspace, gitignored. `scripts/build-web.sh` then selectively copies files into the Swift Resources directory (so stray build artifacts don't leak into Resources).
  - `build.assetsInlineLimit: 0` — forces `.wasm` to emit as a separate file rather than inline as a data URL, so the browser can stream it via `WebAssembly.instantiateStreaming`.
- **`tsconfig.json`** — `strict: true`. `module: "ESNext"`, `target: "ES2020"`, `jsx: "react-jsx"`, `moduleResolution: "bundler"`.
- **`src/main.tsx`** — mounts `<RouterProvider router={router} />` to `#root`. Four lines.
- **`src/router.tsx`** — imports the route definitions, calls `createRouter({ routeTree, history: createHashHistory() or createBrowserHistory() })`. Uses **browser history** (clean URLs like `/session/foo`) since the Graftty server serves `index.html` at `/` and client-side routing takes over. Exports a typed `router` singleton.
- **`src/routes/__root.tsx`** — defines the root route. Renders a minimal shell: `<div id="app"><Outlet /></div>`. No navigation chrome (single-pane app); the status chrome lives inside `TerminalPane`.
- **`src/routes/index.tsx`** — defines the `/` route. If `location.search` has a `?session=<name>` query param, redirects to `/session/<name>` (backward compatibility with the `WebURLComposer` URL format that predates this PR). Otherwise renders a simple "no session selected" placeholder.
- **`src/routes/session.$name.tsx`** — defines `/session/$name`. Reads the typed `name` param from `useParams()`, passes it to `<TerminalPane sessionName={name} />`.
- **`src/components/TerminalPane.tsx`** — the whole terminal runtime. Pseudocode shape:
  ```tsx
  export function TerminalPane({ sessionName }: { sessionName: string }) {
    const [status, setStatus] = useState<'connecting' | 'connected' | 'disconnected' | string>('connecting');
    const { ref, write, onData, onResize } = useTerminal({ theme: ... });
    const wsRef = useRef<WebSocket | null>(null);

    useEffect(() => {
      const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws?session=${encodeURIComponent(sessionName)}`);
      ws.binaryType = 'arraybuffer';
      ws.onopen = () => setStatus(sessionName);
      ws.onmessage = (ev) => {
        if (ev.data instanceof ArrayBuffer) write(new Uint8Array(ev.data));
        else handleControl(ev.data);
      };
      ws.onclose = () => setStatus('disconnected');
      ws.onerror = () => setStatus('error');
      wsRef.current = ws;
      return () => ws.close();
    }, [sessionName]);

    onData((bytes) => { wsRef.current?.send(bytes); });
    onResize(({ cols, rows }) => {
      wsRef.current?.send(JSON.stringify({ type: 'resize', cols, rows }));
    });

    return (
      <>
        <div id="status">{status}</div>
        <div ref={ref} id="term" />
      </>
    );
  }
  ```
  The exact hook API (`write`/`onData`/`onResize` vs a different shape) is TBD at implementation — to be confirmed against `@wterm/react`'s published types. The semantic contract (byte-for-byte protocol compatibility with the current server) is fixed.
- **`src/styles.css`** — full-height container, dark background, status-overlay positioning. wterm theme is set on `:root` via CSS custom properties (`--wterm-foreground`, etc.) so Graftty can later theme it from settings without touching the JS.

### New — `scripts/build-web.sh`

Mirrors the shape of `scripts/bump-zmx.sh`. Idempotent bash script with `set -euo pipefail`. Responsibilities:

1. Check `pnpm --version` exists; if not, print a clear install hint and exit 1.
2. `cd web-client && pnpm install --frozen-lockfile && pnpm build`.
3. Copy from `web-client/dist-tmp/`:
   - `index.html` → `Sources/GrafttyKit/Web/Resources/index.html`
   - `app.js` → `Sources/GrafttyKit/Web/Resources/app.js`
   - `app.css` → `Sources/GrafttyKit/Web/Resources/app.css`
   - `wterm.wasm` (or whatever filename `@wterm/react` emits) → `Sources/GrafttyKit/Web/Resources/wterm.wasm`
4. Write `Resources/VERSION` with: wterm-react package version, wterm git SHA, build timestamp.
5. Print a diff summary so the developer knows what changed.

The script does NOT run on `swift build`. It's an explicit step — developer runs it when they change the frontend.

### Modified — `Sources/GrafttyKit/Web/WebServer.swift` (SPA fallback)

When the browser visits `/session/graftty-abc123` directly (bookmark, shared link, manual type-in), the client-side router hasn't loaded yet — the server has to serve `index.html` for that path, and the router takes over once the JS executes. **Any GET request that doesn't resolve to a known static asset and doesn't start with `/ws` should return the `index.html` body.** This is the standard SPA fallback and is what enables browser-history routing. Paths starting with `/ws` keep their current handling (WebSocket upgrade or 404). `/api/...` paths don't exist yet in Phase 2; if Phase 3 adds them, they'd sit alongside `/ws` on the allowlist.

This is one small code edit in `HTTPHandler`'s request-dispatch logic: the `default:` branch of its path switch serves `index.html` instead of `404`.

### Modified — `Sources/GrafttyKit/Web/WebURLComposer.swift`

Today's composer emits `http://<ip>:<port>/?session=<name>`. Update it to emit `http://<ip>:<port>/session/<name>` (path-based). The `WebURLComposerTests` updates accordingly. The old form still works at runtime because of the index-route redirect (see `src/routes/index.tsx`), so sidebar "Copy web URL" links that users might have already pasted into notes will still function.

### Modified — `Sources/GrafttyKit/Web/WebStaticResources.swift`

Replace the hardcoded URL-path switch with a small two-stage lookup:

```swift
public static func asset(for urlPath: String) throws -> Asset {
    let filename = try resolveFilename(urlPath)
    let (base, ext) = splitName(filename)
    guard let url = Bundle.module.url(forResource: base, withExtension: ext) else {
        throw Error.missingResource(filename)
    }
    let data = try Data(contentsOf: url)
    return Asset(contentType: contentType(forExtension: ext), data: data)
}

private static func resolveFilename(_ urlPath: String) throws -> String {
    switch urlPath {
    case "/", "/index.html": return "index.html"
    case "/app.js":           return "app.js"
    case "/app.css":          return "app.css"
    case "/wterm.wasm":       return "wterm.wasm"
    default: throw Error.missingResource(urlPath)
    }
}

// In WebServer's HTTPHandler, after looking up an asset:
//   if asset not found and path doesn't start with "/ws":
//     return index.html  (SPA fallback — TanStack Router takes over)
//   else:
//     404

private static func contentType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js":   return "application/javascript; charset=utf-8"
    case "css":  return "text/css; charset=utf-8"
    case "wasm": return "application/wasm"
    default:     return "application/octet-stream"
    }
}
```

The swap has one non-obvious requirement: **`.wasm` must be served with `Content-Type: application/wasm`**. `WebAssembly.instantiateStreaming()` rejects any other MIME type. Getting this wrong fails closed (browser throws) but produces a confusing error; the integration test below pins it.

### Modified — `Sources/GrafttyKit/Web/WebServer.swift`

Potentially: add `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` on every HTTP response. Required **only** if wterm uses `SharedArrayBuffer` in its WASM core. To be verified at implementation time (see §Error Handling). If not required, this file is unchanged.

### Modified — `Package.swift`

No changes. The `resources: [.copy("Web/Resources")]` declaration already captures the directory's contents; new files appear automatically.

### Modified — `README.md`

Add a "Developing the web client" section:

> Graftty's web access client lives in `web-client/` (React + Vite + TypeScript). When you change it, run `./scripts/build-web.sh` to rebuild the bundle that ships with the app. CI verifies the committed bundle matches a fresh build.
>
> You need `node` (LTS) and `pnpm` installed locally for web-client work. If you only touch Swift, you need neither — the committed bundle is what `swift build` ships.

### Modified — CI config

Whatever runs on PRs today gets a new early step:

```
./scripts/build-web.sh
git diff --exit-code Sources/GrafttyKit/Web/Resources/
```

If the committed Resources don't match a fresh build, CI fails. The error message is obvious ("developer forgot to run build-web.sh"). No drift between source and built artifact.

### Modified — `SPECS.md §15 Web Access`

- **WEB-3.1** — rewrite to "the application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client."
- New **WEB-3.x** (after 3.1) — "When a client requests any path that does not match a bundled static asset and does not begin with `/ws`, the application shall respond with the bundled `index.html` body and content-type `text/html; charset=utf-8`. This serves the SPA fallback for client-side-routed URLs such as `/session/<name>`."
- New **WEB-3.y** (after WEB-3.x) — "When a client requests `/wterm.wasm` (or any `.wasm` resource), the application shall respond with `Content-Type: application/wasm`."
- **WEB-5.1** — rewrite to "the bundled client shall render a single terminal (wterm) that attaches to the session indicated by the `/session/<name>` URL path. The root path `/` shall redirect to `/session/<name>` when a `?session=<name>` query parameter is present (backward compatibility)."
- **WEB-5.2** — no behavioral change; reword to not name the emulator ("The client shall send terminal data events as binary WebSocket frames.").
- Add **WEB-3.z** only if COEP/COOP is required (see Error Handling): "The application shall respond to every HTTP request with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` headers."

### Removed

`Sources/GrafttyKit/Web/Resources/xterm.min.js`, `xterm.min.css`, `xterm-addon-fit.min.js`.

### Unchanged

Everything else. `WebSession`, `PtyProcess`, `TailscaleLocalAPI`, `WebControlEnvelope`, `WebURLComposer`, `WebServerController`, `WebSettingsPane`, the entire zmx layer, the entire native-pane layer. The WebSocket protocol bytes are untouched.

## Data Flow

**Flow 1 — browser loads `/session/<name>`**

1. `GET /session/<name>` passes the `WhoIs` gate (unchanged).
2. The path doesn't match any static asset. `HTTPHandler`'s SPA fallback kicks in: server returns the Vite-generated `index.html`.
3. Browser parses HTML, requests `/app.css` and `/app.js`. Served from Resources.
4. `app.js` runs. React mounts `<RouterProvider>`. TanStack Router reads `location.pathname` (`/session/<name>`), matches `session.$name.tsx`, and renders `<TerminalPane sessionName="<name>">`.
5. `@wterm/react` initializes its WASM core by fetching `/wterm.wasm`. Server serves it with `Content-Type: application/wasm`; `WebAssembly.instantiateStreaming()` succeeds.
6. Terminal DOM renders. `TerminalPane`'s `useEffect` opens a WebSocket to `/ws?session=<encoded>`.

**Flow 1b — browser loads legacy `/?session=<name>`**

1. `GET /?session=<name>` passes the WhoIs gate. Path `/` matches; server returns `index.html`.
2. Router lands on `src/routes/index.tsx`. The index route reads `location.search`, sees `?session=<name>`, and calls `navigate({ to: '/session/$name', params: { name } })`. Router rewrites the URL path and re-renders into the session route.
3. From here: identical to Flow 1 from step 4 onward.

**Flow 2 — keystrokes from browser** — identical to Phase 2. `@wterm/react`'s `onData` callback emits UTF-8-encoded key bytes; `App.tsx` sends them as a binary WS frame.

**Flow 3 — output to browser** — identical to Phase 2. Server sends binary WS frame with PTY bytes; `App.tsx` calls the hook's `write(Uint8Array)` with the payload.

**Flow 4 — resize** — identical to Phase 2. `@wterm/react`'s `onResize` callback fires with `{ cols, rows }`; `App.tsx` sends `{"type":"resize","cols":N,"rows":M}` as a text frame. Server-side `ioctl(TIOCSWINSZ)` path is unchanged.

**Flow 5 — WS close / disconnect / app quit** — identical to Phase 2. Server-side behavior unchanged; client's React cleanup effect calls `ws.close()` on unmount.

The only new byte moving across the network compared to Phase 2 is `wterm.wasm` on first page load.

## Error Handling

The principle from Phase 2 carries forward: **Graftty remains fully usable with the web feature disabled or broken. The server's public contract is unchanged, so all Phase 2 failure modes are preserved.**

### New failure modes

- **`wterm.wasm` missing from bundle** (botched release build) — `WebStaticResources.asset(for: "/wterm.wasm")` throws `missingResource`. Server returns `404`. Browser logs a clear error; the app status line shows "error". Pinned by the `servesWasmWithCorrectMime` integration test: if the file were missing, the test would fail before any user saw it.
- **`.wasm` served with wrong content-type** — browser's `WebAssembly.instantiateStreaming()` rejects with `TypeError: Incorrect response MIME type`. Pinned by the same integration test, which asserts both status 200 AND content-type.
- **`build-web.sh` forgot to run before commit** — CI fails on `git diff --exit-code`. Developer re-runs the script and re-commits. No runtime impact; caught pre-merge.
- **`pnpm install --frozen-lockfile` fails in CI** (registry outage, lockfile drift) — CI fails at the build step. No impact on release builds, since the release artifact is already in Resources.
- **Developer runs `./scripts/build-web.sh` without node/pnpm installed** — script prints an install hint and exits 1. No partial-write hazard.

### Conditional: COEP/COOP headers

wterm's WASM core may or may not use `SharedArrayBuffer`. If it does, the browser requires **cross-origin isolation** via two response headers on **every** HTTP response:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

Verification plan at implementation time:

1. Complete the bundle swap without adding headers.
2. Open the app in Safari. Open the browser console.
3. If the console shows a COEP/COOP error before the terminal renders, add the headers to `HTTPHandler.handle(…)` in `WebServer.swift`, update `SPECS.md` with **WEB-3.y**, rebuild.
4. If no error, headers are not added, and **WEB-3.y** stays out of SPECS.md.

This is not a placeholder — it's an explicit decision gate with a reproducible test. The answer is determined by running the code once.

### Phase 2 failure modes — all preserved

Tailscale-not-running, WhoIs-denies-peer, port-unavailable, zmx-attach-fails, attach-child-exits, session-ended: all unchanged because the server's public contract is unchanged.

## Testing

### Unit tests — `Tests/GrafttyKitTests/Web/`

Existing `WebStaticResources` unit test (if one exists; if not, add one):

- Assert `asset(for: "/")` returns HTML.
- Assert `asset(for: "/app.js")` returns JavaScript.
- Assert `asset(for: "/app.css")` returns CSS.
- **New:** Assert `asset(for: "/wterm.wasm")` returns a non-empty payload with `Content-Type: application/wasm`, and that the first four bytes are the WASM magic `\x00\x61\x73\x6d`.
- Assert `asset(for: "/does-not-exist")` throws `missingResource`.

### Integration tests — `Tests/GrafttyKitTests/Web/WebServerIntegrationTests.swift`

- **`startsAndServesIndex`** — update the HTML-content assertion from "contains xterm.js script tag" to "contains `<script type=\"module\" src=\"./app.js\">` and `<div id=\"root\">`".
- **`servesWasmWithCorrectMime`** — **NEW**. GET `/wterm.wasm`, assert response code 200, assert `Content-Type: application/wasm`, assert body is non-empty and begins with `\x00\x61\x73\x6d`.
- **`spaFallbackServesIndex`** — **NEW**. GET `/session/any-name-here`, assert response code 200 and content-type `text/html; charset=utf-8`, body matches the same `index.html` served at `/`. GET `/anything/else` likewise. Verifies the SPA fallback works for any non-`/ws`, non-asset path.
- **`wsPathStill404sIfNotUpgraded`** — **NEW**. GET `/ws` without an Upgrade header returns 404 (NOT index.html). Prevents the SPA fallback from masking WebSocket handling regressions.
- **`attachesAndEchoes`**, **`deniesNonOwner`**, **`resizesPty`**, **`closesChildOnWsDisconnect`** — unchanged. These exercise server behavior, not client behavior. They continue to prove bytes round-trip through the WS protocol.

### Unit tests — `Tests/GrafttyKitTests/Web/WebURLComposerTests.swift`

- Existing cases pinning the `/?session=` URL format: update to assert the new path-based format `http://<ip>:<port>/session/<name>`.
- All IPv4 / IPv6 bracket / host-selection logic is unchanged.

### Frontend tests — intentionally none for this sub-project

The React component is a thin wrapper over `useTerminal` + a WebSocket. Its logic is end-to-end-tested by the server-side `attachesAndEchoes` integration test: a round-trip byte echo proves both that the client can render bytes it receives and emit keystrokes over the WS. Phase 3 sub-projects (routing, state management, multi-pane layout) will introduce logic that warrants component tests; that's not this spec.

### Manual smoke checklist — `docs/superpowers/plans/ZmxWebAccessSmokeChecklist.md`

Update from Phase 2's six steps to seven. Insert one new step after today's step 1:

> **Step 1.5 (new).** In Safari on the phone, long-press a word of terminal output. A **native** iOS text-selection handle should appear (not a canvas-rendered pseudo-selection). Copy the selected text; paste into another app; confirm the bytes match what was on screen. This validates the core UX reason for adopting wterm.

The other six steps are unchanged. Step 5 ("Tailscale unavailable") and step 6 ("browser tab closed while command runs") particularly matter to re-run — they prove the server-side posture survived the swap.

## Acceptance Criteria

This PR is done when all of the following hold:

1. `swift test` passes with the same skip set as before (no new skips). The new `servesWasmWithCorrectMime` test passes on every platform CI exercises.
2. `./scripts/build-web.sh && git diff --exit-code` produces no diff from a clean checkout.
3. The updated seven-step smoke checklist passes, including the new native-text-selection step.
4. `SPECS.md §15` reflects current reality: no "xterm.js" references; **WEB-3.x** (WASM MIME) added; **WEB-3.y** (COEP/COOP) added iff wterm required it at implementation time.
5. `README.md` documents node + pnpm as optional dev prerequisites; Homebrew install still requires zero JS tooling.
6. Apache-2.0 `LICENSE-wterm` is present in `Sources/GrafttyKit/Web/Resources/` alongside the bundle. `NOTICE-wterm` is present iff upstream ships a NOTICE file.
7. The three files `xterm.min.js`, `xterm.min.css`, `xterm-addon-fit.min.js` are removed from Resources.

## Architectural Notes

### Why TanStack Router (not TanStack Start) and not React Router

TanStack Router gives us type-safe, file-colocated routes without committing to a Node runtime. TanStack Start would be the full-stack framework (SSR + server routes + loaders on Nitro) — its value props don't apply here because Graftty's server is Swift + swift-nio, not Node. Running Start in SPA-only mode would pay the framework's weight for one feature. Using just the router keeps this PR small and leaves the door open for Start's features in a future world where the architecture changes (which isn't anywhere on the roadmap).

React Router is the obvious alternative. TanStack Router wins on: type-safe params (`$name` in the path becomes a typed `{ name: string }` in the component), smaller bundle for the features used, and better fit with TanStack Query if Phase 3 pulls that in. No strong loss — both would work here. Defaulting to TanStack Router matches the Phase 2 spec's own reference to "TanStack" for Phase 3.

### Why Vite over esbuild, webpack, Rollup, tsup

Vite gives us a zero-config React + TypeScript build with one `vite build` invocation. The output is exactly what we need (static HTML/JS/CSS/WASM), it handles the React JSX transform, and it's what `@wterm/react` examples use. esbuild is a lower-level tool; webpack is overkill for a single-page app this small; Rollup is what Vite uses under the hood. No strong runner-up; Vite is the default for React-in-2026.

### Why commit the built bundle rather than build on `swift build`

Graftty's release pipeline (Homebrew tap) distributes a prebuilt Mac app. End users never run `swift build`; they install a binary. Committing the JS bundle keeps the release tarball self-contained with zero new build prerequisites for end users. Developers who touch only Swift are also unaffected — `swift build` alone produces a working app.

The alternative (SwiftPM build-tool plugin that invokes pnpm at build time) would either require node+pnpm at every `swift build`, or would produce a release artifact whose reproducibility depends on the builder's node version. Neither is worth the "never need to remember `build-web.sh`" convenience.

### Why no content-hashed filenames

The Graftty web server is bound to a user-visible port and serves from a specific machine on demand. Browser caches don't meaningfully apply — the whole app reloads on tab open. Cache-busting via content hashes buys nothing here and costs the `WebStaticResources.asset(for:)` map its simplicity. Flat filenames are the simpler tool for this job.

### Why no frontend test framework

Adding Vitest or Jest to a workspace whose entire logic is "WebSocket ↔ useTerminal hook" is weight for nothing. The integration tests on the Swift side exercise the exact contract the client is on the other end of. If a future Phase 3 sub-project adds non-trivial client logic (state reducers, route guards, data-fetching), that's when frontend tests earn their keep.

### What this PR enables for Phase 3

Phase 3's remaining sub-projects reuse:

- **`web-client/` as a React workspace** — views and state libraries plug in here.
- **TanStack Router** — future sub-projects add routes (`/worktrees`, `/worktree/$id/pane/$name`, etc.) without introducing a routing library.
- **The Vite + pnpm + TypeScript toolchain** — no further setup cost.
- **The `app.js`/`app.css` predictable filename convention** — Vite can emit more chunks without re-designing `WebStaticResources`.
- **The committed-dist + CI-verify pattern** — same rhythm for every future web-UI PR.
- **The SPA fallback behavior in `WebServer`** — any future client-routed path (`/worktree/<id>`, `/settings`) Just Works without a server code change.

What Phase 3 adds on top: a data layer for subscribing to server-pushed session/worktree/attention events, a sidebar component, a split-layout component, mobile media queries. None of those requires re-visiting this spec's decisions.

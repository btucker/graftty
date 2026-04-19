# wterm Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace xterm.js with wterm in Espalier's web access client; introduce a React + Vite + TypeScript + TanStack Router workspace at `web-client/`; keep the Swift server contract unchanged except for SPA fallback and a URL-composer tweak.

**Architecture:** New `web-client/` pnpm workspace builds a small React SPA. Built artifacts (`index.html`, `app.js`, `app.css`, `wterm.wasm`) commit into `Sources/EspalierKit/Web/Resources/` and are served by the existing Swift HTTPHandler. TanStack Router owns `/` and `/session/$name`. The root route redirects legacy `/?session=<name>` URLs to `/session/<name>`. A small `HTTPHandler` edit adds SPA-fallback so client-side-routed paths resolve to `index.html`.

**Tech Stack:** React 19, Vite 6, TypeScript 5, TanStack Router 1.x, @wterm/react (latest), pnpm, Swift + swift-nio (existing).

**Spec:** `docs/superpowers/specs/2026-04-19-wterm-adoption-design.md`.

---

## Pre-flight

- [ ] **Verify node + pnpm are installed**

```bash
node --version && pnpm --version
```

Expected: node 20+ and pnpm 9+. If missing, install via `brew install node pnpm`.

- [ ] **Verify starting test suite is green**

```bash
cd /Users/btucker/projects/espalier/.worktrees/wterm
swift test 2>&1 | tail -20
```

Expected: all tests pass or the familiar skipped-without-zmx set.

---

## Task 1: Scaffold the web-client workspace (files only)

Create the workspace layout. No `pnpm install` yet — that lands in Task 2. Nothing is wired to Swift yet.

**Files:**
- Create: `web-client/package.json`
- Create: `web-client/tsconfig.json`
- Create: `web-client/vite.config.ts`
- Create: `web-client/index.html`
- Create: `web-client/.gitignore`
- Create: `web-client/src/main.tsx`
- Create: `web-client/src/router.tsx`
- Create: `web-client/src/routes/__root.tsx`
- Create: `web-client/src/routes/index.tsx`
- Create: `web-client/src/routes/session.$name.tsx`
- Create: `web-client/src/components/TerminalPane.tsx`
- Create: `web-client/src/styles.css`

- [ ] **Step 1.1: Create `web-client/package.json`**

```json
{
  "name": "espalier-web-client",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "build": "vite build"
  },
  "dependencies": {
    "@tanstack/react-router": "^1.95.0",
    "@wterm/react": "latest",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.7.0",
    "vite": "^6.0.0"
  }
}
```

- [ ] **Step 1.2: Create `web-client/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "resolveJsonModule": true,
    "allowImportingTsExtensions": false,
    "noEmit": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"]
  },
  "include": ["src"]
}
```

- [ ] **Step 1.3: Create `web-client/vite.config.ts`**

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: '../dist-tmp',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'chunk-[name].js',
        assetFileNames: (info) => {
          const name = info.name ?? 'asset';
          if (name.endsWith('.css')) return 'app.css';
          return name;
        },
      },
    },
  },
});
```

- [ ] **Step 1.4: Create `web-client/index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Espalier</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

Note: in the built output, the script tag is rewritten to `./app.js` automatically by Vite.

- [ ] **Step 1.5: Create `web-client/.gitignore`**

```
node_modules/
dist-tmp/
```

- [ ] **Step 1.6: Create `web-client/src/main.tsx`**

```tsx
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { RouterProvider } from '@tanstack/react-router';
import { router } from './router';
import './styles.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
```

- [ ] **Step 1.7: Create `web-client/src/router.tsx`**

```tsx
import { createRouter, createRootRoute, createRoute } from '@tanstack/react-router';
import { RootLayout } from './routes/__root';
import { IndexPage } from './routes/index';
import { SessionPage } from './routes/session.$name';

const rootRoute = createRootRoute({ component: RootLayout });

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  component: IndexPage,
});

const sessionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/session/$name',
  component: SessionPage,
});

const routeTree = rootRoute.addChildren([indexRoute, sessionRoute]);

export const router = createRouter({ routeTree });
```

- [ ] **Step 1.8: Create `web-client/src/routes/__root.tsx`**

```tsx
import { Outlet } from '@tanstack/react-router';

export function RootLayout() {
  return (
    <div id="app">
      <Outlet />
    </div>
  );
}
```

- [ ] **Step 1.9: Create `web-client/src/routes/index.tsx`**

```tsx
import { useEffect } from 'react';
import { useNavigate } from '@tanstack/react-router';

export function IndexPage() {
  const navigate = useNavigate();
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const session = params.get('session');
    if (session) {
      void navigate({ to: '/session/$name', params: { name: session }, replace: true });
    }
  }, [navigate]);

  return <div id="status">no session selected</div>;
}
```

- [ ] **Step 1.10: Create `web-client/src/routes/session.$name.tsx`**

```tsx
import { useParams } from '@tanstack/react-router';
import { TerminalPane } from '../components/TerminalPane';

export function SessionPage() {
  const { name } = useParams({ from: '/session/$name' });
  return <TerminalPane sessionName={name} />;
}
```

- [ ] **Step 1.11: Create `web-client/src/components/TerminalPane.tsx`**

Use the exact hook shape documented by `@wterm/react` once its types are known. This initial version makes reasonable assumptions; Task 2's first-build step verifies against the real types and this file gets corrected if the API differs.

```tsx
import { useEffect, useRef, useState } from 'react';
import { useTerminal } from '@wterm/react';

type Status = 'connecting' | 'disconnected' | 'error' | string;

export function TerminalPane({ sessionName }: { sessionName: string }) {
  const [status, setStatus] = useState<Status>('connecting');
  const { ref, write, onData, onResize } = useTerminal();
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(
      `${proto}//${window.location.host}/ws?session=${encodeURIComponent(sessionName)}`,
    );
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => setStatus(sessionName);
    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) {
        write(new Uint8Array(ev.data));
      } else {
        try {
          const msg = JSON.parse(String(ev.data));
          if (msg?.type === 'error' || msg?.type === 'sessionEnded') {
            setStatus(msg.message || msg.type);
          }
        } catch {
          /* ignore non-JSON text frames */
        }
      }
    };
    ws.onclose = () => setStatus('disconnected');
    ws.onerror = () => setStatus('error');
    wsRef.current = ws;

    return () => {
      ws.close();
      wsRef.current = null;
    };
  }, [sessionName, write]);

  onData((bytes: Uint8Array) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(bytes);
  });

  onResize(({ cols, rows }: { cols: number; rows: number }) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }));
    }
  });

  return (
    <>
      <div id="status">{status}</div>
      <div id="term" ref={ref} />
    </>
  );
}
```

- [ ] **Step 1.12: Create `web-client/src/styles.css`**

```css
:root {
  color-scheme: dark;
  --wterm-background: #0d0d0d;
  --wterm-foreground: #e5e5e5;
}

html, body, #root, #app {
  margin: 0;
  height: 100%;
  background: var(--wterm-background);
  color: var(--wterm-foreground);
  font-family: Menlo, monospace;
}

#term {
  height: 100vh;
  padding: 8px;
  box-sizing: border-box;
}

#status {
  position: fixed;
  top: 4px;
  right: 8px;
  color: #888;
  font: 12px monospace;
  pointer-events: none;
}
```

- [ ] **Step 1.13: Commit scaffolding**

```bash
git add web-client/
git commit -m "feat(web): scaffold React + Vite + TanStack Router web-client workspace

Part of wterm adoption. Layout only — no deps installed, no build produced.
See docs/superpowers/specs/2026-04-19-wterm-adoption-design.md."
```

---

## Task 2: Install deps and produce the first successful build

First real `pnpm install` + build. Verify TerminalPane compiles against the real `@wterm/react` types; correct any type mismatches.

**Files:**
- Create: `web-client/pnpm-lock.yaml` (generated)
- Create: `web-client/dist-tmp/` (ignored; transient)
- Possibly modify: `web-client/src/components/TerminalPane.tsx` (if hook shape differs)

- [ ] **Step 2.1: Install deps**

```bash
cd web-client
pnpm install
```

Expected: dependencies resolve, `pnpm-lock.yaml` created. If `@wterm/react` @latest doesn't resolve (brand-new package), look up the correct name and version at https://github.com/vercel-labs/wterm/tree/main/packages/%40wterm/react and pin it in `package.json`.

- [ ] **Step 2.2: Attempt first build**

```bash
cd web-client
pnpm build 2>&1
```

If this fails on `TerminalPane.tsx` with type errors on `useTerminal`, inspect the real exported type:

```bash
cat node_modules/@wterm/react/dist/index.d.ts
```

Adjust `TerminalPane.tsx` destructuring to match. The semantic target remains: receive bytes from server → display in terminal; emit user-typed bytes → send over WS; emit resize events → send resize envelope. Do the minimal correction; do not restructure the whole component.

Expected final state: build succeeds, `web-client/dist-tmp/` contains `index.html`, `app.js`, `app.css`, and a `.wasm` file (exact filename TBD — maybe `wterm.wasm` or a hashed name via the wterm package's own emit).

- [ ] **Step 2.3: Verify WASM file presence and filename**

```bash
ls web-client/dist-tmp/
```

If the `.wasm` file is named something like `wterm-CORE.wasm` or has a hash, note the filename for Task 3 (the copy script needs the exact name). If Vite emits it at `dist-tmp/assets/<name>.wasm`, note that too.

- [ ] **Step 2.4: Commit lockfile and correction (if any)**

```bash
git add web-client/pnpm-lock.yaml web-client/src/components/TerminalPane.tsx web-client/package.json
git commit -m "feat(web): install web-client deps; align TerminalPane to real @wterm/react API"
```

---

## Task 3: Build-and-vendor script, remove xterm assets

Write `scripts/build-web.sh`, run it to publish artifacts into `Sources/EspalierKit/Web/Resources/`, and delete the xterm artifacts in the same commit (kept together so the Swift side never sees stale resources).

**Files:**
- Create: `scripts/build-web.sh`
- Modify: root `.gitignore` (add `web-client/dist-tmp/`)
- Modify: `Sources/EspalierKit/Web/Resources/index.html` (overwritten)
- Create: `Sources/EspalierKit/Web/Resources/app.js`
- Create: `Sources/EspalierKit/Web/Resources/app.css`
- Create: `Sources/EspalierKit/Web/Resources/wterm.wasm`
- Modify: `Sources/EspalierKit/Web/Resources/VERSION`
- Delete: `Sources/EspalierKit/Web/Resources/xterm.min.js`
- Delete: `Sources/EspalierKit/Web/Resources/xterm.min.css`
- Delete: `Sources/EspalierKit/Web/Resources/xterm-addon-fit.min.js`

- [ ] **Step 3.1: Add `web-client/dist-tmp/` to root .gitignore**

Edit root `.gitignore`. Append:

```
web-client/dist-tmp/
web-client/node_modules/
```

- [ ] **Step 3.2: Create `scripts/build-web.sh`**

Adjust the `cp` paths in step 3.2 based on the exact filenames discovered in Task 2 Step 2.3.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/web-client"
RES="$ROOT/Sources/EspalierKit/Web/Resources"

if ! command -v pnpm >/dev/null 2>&1; then
  echo "ERROR: pnpm not found. Install with: brew install pnpm" >&2
  exit 1
fi

echo "→ pnpm install (frozen lockfile)"
(cd "$WEB" && pnpm install --frozen-lockfile)

echo "→ pnpm build"
(cd "$WEB" && pnpm build)

echo "→ copying build artifacts to $RES"
cp "$WEB/dist-tmp/index.html" "$RES/index.html"
cp "$WEB/dist-tmp/app.js"     "$RES/app.js"
cp "$WEB/dist-tmp/app.css"    "$RES/app.css"

# Locate the .wasm output — either at dist-tmp/ root or dist-tmp/assets/.
WASM_SRC=""
for cand in "$WEB/dist-tmp"/*.wasm "$WEB/dist-tmp/assets"/*.wasm; do
  [ -f "$cand" ] && { WASM_SRC="$cand"; break; }
done
if [ -z "$WASM_SRC" ]; then
  echo "ERROR: could not find a .wasm file under $WEB/dist-tmp/" >&2
  exit 1
fi
cp "$WASM_SRC" "$RES/wterm.wasm"

WTERM_VER=$(cd "$WEB" && node -p "require('./node_modules/@wterm/react/package.json').version" 2>/dev/null || echo "unknown")
GIT_SHA=$(cd "$ROOT" && git rev-parse --short HEAD)
printf "wterm-react: %s\nespalier-build-sha: %s\nbuilt: %s\n" "$WTERM_VER" "$GIT_SHA" "$(date -u +%FT%TZ)" > "$RES/VERSION"

echo "→ done. Artifacts in $RES:"
ls -la "$RES"
```

Make it executable:

```bash
chmod +x scripts/build-web.sh
```

- [ ] **Step 3.3: Run the build script**

```bash
cd /Users/btucker/projects/espalier/.worktrees/wterm
./scripts/build-web.sh
```

Expected: script completes; `Sources/EspalierKit/Web/Resources/` contains fresh `index.html`, `app.js`, `app.css`, `wterm.wasm`, and an updated `VERSION`.

If the script references a `.wasm` path that doesn't exist, adjust the `cp` logic to match the real Vite output layout, then re-run.

- [ ] **Step 3.4: Delete stale xterm assets**

```bash
rm Sources/EspalierKit/Web/Resources/xterm.min.js
rm Sources/EspalierKit/Web/Resources/xterm.min.css
rm Sources/EspalierKit/Web/Resources/xterm-addon-fit.min.js
```

- [ ] **Step 3.5: Stage and commit**

```bash
git add scripts/build-web.sh .gitignore Sources/EspalierKit/Web/Resources/
git commit -m "feat(web): build-web.sh; swap xterm.js resources for wterm bundle"
```

---

## Task 4: Add LICENSE-wterm (and NOTICE if upstream ships one)

Apache 2.0 attribution obligations.

**Files:**
- Create: `Sources/EspalierKit/Web/Resources/LICENSE-wterm`
- Possibly create: `Sources/EspalierKit/Web/Resources/NOTICE-wterm`

- [ ] **Step 4.1: Pull LICENSE from upstream**

```bash
curl -fL -o Sources/EspalierKit/Web/Resources/LICENSE-wterm https://raw.githubusercontent.com/vercel-labs/wterm/main/LICENSE
```

Expected: file downloads; first line reads "Apache License".

- [ ] **Step 4.2: Check for upstream NOTICE file**

```bash
curl -fL -o /tmp/wterm-NOTICE https://raw.githubusercontent.com/vercel-labs/wterm/main/NOTICE 2>/dev/null && mv /tmp/wterm-NOTICE Sources/EspalierKit/Web/Resources/NOTICE-wterm || echo "No NOTICE file upstream — skipping"
```

If upstream has no NOTICE, skip creating one. Apache 2.0 only requires NOTICE reproduction if upstream ships one.

- [ ] **Step 4.3: Commit**

```bash
git add Sources/EspalierKit/Web/Resources/LICENSE-wterm Sources/EspalierKit/Web/Resources/NOTICE-wterm 2>/dev/null || git add Sources/EspalierKit/Web/Resources/LICENSE-wterm
git commit -m "docs(web): include wterm Apache-2.0 LICENSE (and NOTICE if upstream ships one)"
```

---

## Task 5: Update WebStaticResources.swift — MIME map + asset table (TDD)

Add `/wterm.wasm` to the asset table, replace the hardcoded xterm paths with `app.js`/`app.css`, add `application/wasm` content type. Use extension-based MIME lookup so future assets don't need code changes.

**Files:**
- Modify: `Sources/EspalierKit/Web/WebStaticResources.swift`
- Modify: `Tests/EspalierKitTests/Web/WebStaticResourcesTests.swift`

- [ ] **Step 5.1: Read existing tests to understand the test style**

```bash
cat Tests/EspalierKitTests/Web/WebStaticResourcesTests.swift
```

Match the style (XCTest vs Swift Testing, assertion conventions).

- [ ] **Step 5.2: Write failing test for `app.js` and `wterm.wasm`**

The file uses `swift-testing` (`@Test` / `#expect`). Add these tests inside the `struct WebStaticResourcesTests` body. Also **delete** the existing `loadsXtermJS` and `loadsXtermCSS` tests (they reference removed files):

```swift
@Test func loadsAppJS() throws {
    let asset = try WebStaticResources.asset(for: "/app.js")
    #expect(asset.data.count > 100)
    #expect(asset.contentType == "application/javascript; charset=utf-8")
}

@Test func loadsAppCSS() throws {
    let asset = try WebStaticResources.asset(for: "/app.css")
    #expect(asset.data.count > 0)
    #expect(asset.contentType == "text/css; charset=utf-8")
}

@Test func loadsWasmWithCorrectMimeAndMagic() throws {
    let asset = try WebStaticResources.asset(for: "/wterm.wasm")
    #expect(asset.contentType == "application/wasm")
    #expect(asset.data.count >= 4)
    let magic = Array(asset.data.prefix(4))
    #expect(magic == [0x00, 0x61, 0x73, 0x6d], "WASM file must start with \\x00asm magic")
}

@Test func unknownPathThrows() {
    #expect(throws: WebStaticResources.Error.self) {
        _ = try WebStaticResources.asset(for: "/does-not-exist.txt")
    }
}
```

- [ ] **Step 5.3: Run tests — expect failure**

```bash
swift test --filter WebStaticResourcesTests 2>&1 | tail -30
```

Expected: new tests fail (the resource paths don't exist in the current `asset(for:)` switch).

- [ ] **Step 5.4: Update `WebStaticResources.swift`**

Replace the body of `Sources/EspalierKit/Web/WebStaticResources.swift` with:

```swift
import Foundation

/// Accessors for the Phase 2+ web client bundled via
/// `resources: [.copy("Web/Resources")]`. SPM's copy layout
/// relocates resource files to the bundle root, so lookups use
/// `Bundle.module.url(forResource:withExtension:)` with no
/// `subdirectory:` argument.
public enum WebStaticResources {

    public enum Error: Swift.Error {
        case missingResource(String)
    }

    public struct Asset {
        public let contentType: String
        public let data: Data

        public init(contentType: String, data: Data) {
            self.contentType = contentType
            self.data = data
        }
    }

    public static func asset(for urlPath: String) throws -> Asset {
        let filename = try resolveFilename(urlPath)
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext) else {
            throw Error.missingResource(filename)
        }
        let data = try Data(contentsOf: url)
        return Asset(contentType: contentType(forExtension: ext), data: data)
    }

    /// The bundled `index.html` body — used by the SPA fallback in `WebServer`
    /// so unknown non-`/ws` paths resolve to the client's routing entry point.
    public static func indexHTML() throws -> Asset {
        try asset(for: "/")
    }

    private static func resolveFilename(_ urlPath: String) throws -> String {
        switch urlPath {
        case "/", "/index.html": return "index.html"
        case "/app.js":          return "app.js"
        case "/app.css":         return "app.css"
        case "/wterm.wasm":      return "wterm.wasm"
        default: throw Error.missingResource(urlPath)
        }
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        default:     return "application/octet-stream"
        }
    }
}
```

- [ ] **Step 5.5: Run tests — expect pass**

```bash
swift test --filter WebStaticResourcesTests 2>&1 | tail -30
```

Expected: all four new tests pass. If the existing `testIndexResolves` test (or similar) asserted the old xterm filenames, update it to the new names now.

- [ ] **Step 5.6: Commit**

```bash
git add Sources/EspalierKit/Web/WebStaticResources.swift Tests/EspalierKitTests/Web/WebStaticResourcesTests.swift
git commit -m "feat(web): extension-based MIME map; add wterm.wasm + app.js/app.css entries

Adds application/wasm MIME so WebAssembly.instantiateStreaming() works.
Adds WebStaticResources.indexHTML() accessor for SPA fallback in WebServer."
```

---

## Task 6: SPA fallback in WebServer's HTTPHandler (TDD)

Unknown, non-`/ws` GET paths return `index.html` so TanStack Router can resolve client-side routes like `/session/foo`. HTTP-level tests for the WebServer live in `WebServerAuthTests.swift` (it has the `URLSession.shared.data(from:)` pattern and a helper `makeConfig`). Add these there.

**Files:**
- Modify: `Sources/EspalierKit/Web/WebServer.swift`
- Modify: `Tests/EspalierKitTests/Web/WebServerAuthTests.swift`

- [ ] **Step 6.1: Read the existing HTTPHandler implementation**

```bash
grep -n "HTTPHandler\|channelRead\|asset(for:" Sources/EspalierKit/Web/WebServer.swift | head -40
```

Locate the path-dispatch switch (the place today that returns 404 for unknown paths). The fix goes there.

- [ ] **Step 6.2: Write failing tests — SPA fallback + /ws still 404s + WASM MIME**

Add to `Tests/EspalierKitTests/Web/WebServerAuthTests.swift` inside the `struct WebServerAuthTests { … }`. Match the existing style (use `makeConfig`, start a server, hit `127.0.0.1:<port>`, use `#expect`):

```swift
@Test func spaFallbackServesIndexForUnknownPath() async throws {
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
        bindAddresses: ["127.0.0.1"]
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let (data, response) = try await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)/session/whatever")!
    )
    let http = response as! HTTPURLResponse
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
    let body = String(data: data, encoding: .utf8) ?? ""
    #expect(body.contains("<div id=\"root\">"), "SPA fallback should serve index.html body")
}

@Test func wsPathReturns404WithoutUpgradeHeader() async throws {
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
        bindAddresses: ["127.0.0.1"]
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let (_, response) = try await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)/ws")!
    )
    let http = response as! HTTPURLResponse
    #expect(http.statusCode == 404, "/ws without Upgrade must NOT fall through to index.html")
}

@Test func servesWasmWithApplicationWasmMime() async throws {
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
        bindAddresses: ["127.0.0.1"]
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let (data, response) = try await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)/wterm.wasm")!
    )
    let http = response as! HTTPURLResponse
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/wasm")
    #expect(data.count >= 4)
    let magic = Array(data.prefix(4))
    #expect(magic == [0x00, 0x61, 0x73, 0x6d])
}
```

- [ ] **Step 6.3: Run — expect failure**

```bash
swift test --filter WebServerAuthTests 2>&1 | tail -40
```

Expected: the three new tests fail (today `/session/whatever` returns 404; `/wterm.wasm` returns 404 because the MIME map hasn't been added yet — wait, Task 5 already added this, so that test should already pass if Task 5 ran. If it doesn't, the HTTPHandler may not consult `WebStaticResources.asset(for:)` for the `.wasm` path; the asset-serving switch may need updating too. Step 6.4 covers this.). The SPA-fallback and WS-no-upgrade tests definitely fail.

- [ ] **Step 6.4: Implement SPA fallback + verify `.wasm` is served**

In `WebServer.swift`'s `HTTPHandler`:

1. Locate where GET requests dispatch on the request path. The current shape roughly: `switch requestPath { case "/": … case "/xterm.min.js": … default: 404 }` — or something along those lines. The existing code may hardcode each asset path instead of delegating to `WebStaticResources.asset(for:)`. Refactor so that **every** GET that isn't `/ws`:
   - Tries `WebStaticResources.asset(for: requestPath)`.
   - On success, responds 200 with the asset's content-type and data.
   - On `missingResource`, falls back to `WebStaticResources.indexHTML()` and responds 200 with its content-type and data — **this is the SPA fallback**.
   - `/ws` continues to be handled by the NIO upgrade pipeline exactly as today.

Pseudocode of the post-change default branch:

```swift
// After WhoIs gate passes and request is a GET:
if requestPath == "/ws" || requestPath.hasPrefix("/ws?") {
    // leave to existing WS upgrade path; if no upgrade header, fall through
    respond(404, text: "not found")
    return
}
do {
    let asset = try WebStaticResources.asset(for: requestPath)
    respond(200, contentType: asset.contentType, body: asset.data)
} catch WebStaticResources.Error.missingResource {
    // SPA fallback
    do {
        let index = try WebStaticResources.indexHTML()
        respond(200, contentType: index.contentType, body: index.data)
    } catch {
        respond(404, text: "not found")
    }
}
```

Apply this to the actual code paths. The existing `respond` call shape must be preserved — just change the logic that chooses what to respond with.

- [ ] **Step 6.5: Run — expect pass**

```bash
swift test --filter WebServerAuthTests 2>&1 | tail -40
```

Expected: all auth tests pass (existing two + three new).

- [ ] **Step 6.6: Commit**

```bash
git add Sources/EspalierKit/Web/WebServer.swift Tests/EspalierKitTests/Web/WebServerAuthTests.swift
git commit -m "feat(web): SPA fallback + generic asset delegation in HTTPHandler

Unknown non-/ws GET paths now return index.html so TanStack Router can
resolve /session/\$name and similar URLs loaded directly by the browser.
Asset serving delegates to WebStaticResources.asset(for:) instead of
hardcoding each path, picking up /wterm.wasm automatically."
```

---

## Task 7: Update WebURLComposer for path-based URLs (TDD)

Change `/?session=<name>` → `/session/<name>`.

**Files:**
- Modify: `Sources/EspalierKit/Web/WebURLComposer.swift`
- Modify: `Tests/EspalierKitTests/Web/WebURLComposerTests.swift`

- [ ] **Step 7.1: Read the existing composer and tests**

```bash
cat Sources/EspalierKit/Web/WebURLComposer.swift
cat Tests/EspalierKitTests/Web/WebURLComposerTests.swift
```

- [ ] **Step 7.2: Update test assertions first**

In `WebURLComposerTests.swift`, replace the expected URL strings:

- `"http://100.64.1.7:8799/?session=espalier-abc"` → `"http://100.64.1.7:8799/session/espalier-abc"`
- IPv6 equivalent: `"http://[fd7a:...]:8799/?session=espalier-abc"` → `"http://[fd7a:...]:8799/session/espalier-abc"`

Any test that composes a URL for a session name with URL-unsafe characters should continue to percent-encode the name component — preserve that assertion.

- [ ] **Step 7.3: Run — expect failure**

```bash
swift test --filter WebURLComposerTests 2>&1 | tail -20
```

Expected: assertion failures on URL format.

- [ ] **Step 7.4: Update `WebURLComposer.swift`**

Find the single line that produces the query-string URL and change it. Example (adjust to the real code):

```swift
// Before:
//   return "http://\(host)/?session=\(encoded)"
// After:
//   return "http://\(host)/session/\(encoded)"
```

Keep the bracket logic for IPv6 hosts and the percent-encoding of `<name>`.

- [ ] **Step 7.5: Run — expect pass**

```bash
swift test --filter WebURLComposerTests 2>&1 | tail -20
```

- [ ] **Step 7.6: Commit**

```bash
git add Sources/EspalierKit/Web/WebURLComposer.swift Tests/EspalierKitTests/Web/WebURLComposerTests.swift
git commit -m "feat(web): emit path-based /session/<name> URLs from WebURLComposer

Legacy /?session=<name> URLs still work via the index-route redirect in
the client (web-client/src/routes/index.tsx)."
```

---

## Task 8: Fix `allowedRequestServesHTML` assertion for the Vite-built bundle

`WebServerAuthTests.allowedRequestServesHTML` asserts that the served `/` body contains `"xterm.min.js"` — this fails now that the bundle is wterm. Update the assertion to match the new HTML.

**Files:**
- Modify: `Tests/EspalierKitTests/Web/WebServerAuthTests.swift`

- [ ] **Step 8.1: Run the full Web test suite**

```bash
swift test --filter Web 2>&1 | tail -60
```

Expected: `allowedRequestServesHTML` fails on the `html.contains("xterm.min.js")` assertion.

- [ ] **Step 8.2: Update assertion**

In `WebServerAuthTests.swift`'s `allowedRequestServesHTML`, replace:

```swift
#expect(html.contains("xterm.min.js"))
```

with:

```swift
#expect(html.contains("<div id=\"root\">"))
#expect(html.contains("app.js"))
```

- [ ] **Step 8.3: Rerun**

```bash
swift test --filter Web 2>&1 | tail -60
```

Expected: all Web tests pass. Same zmx-requires-CI skip as before.

- [ ] **Step 8.4: Commit**

```bash
git add Tests/EspalierKitTests/Web/WebServerAuthTests.swift
git commit -m "test(web): update allowedRequestServesHTML assertion for Vite bundle"
```

---

## Task 9: Verify cross-origin isolation (conditional COEP/COOP)

Run the app in a browser; check whether wterm's WASM needs SharedArrayBuffer.

**Files:**
- Possibly modify: `Sources/EspalierKit/Web/WebServer.swift` (header response)
- Possibly modify: `Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift`
- Possibly modify: `SPECS.md`

- [ ] **Step 9.1: Launch Espalier locally**

```bash
swift build && open .build/debug/Espalier  # adjust to the actual launch path
```

Open an Espalier window, enable web access in Settings, open one pane. Copy the web URL.

- [ ] **Step 9.2: Open the URL in Safari with devtools**

Enable Develop → Show Web Inspector. Open the URL. Look for console errors mentioning `Cross-Origin-Embedder-Policy`, `Cross-Origin-Opener-Policy`, `SharedArrayBuffer`, or `require-corp`.

**If NO errors appear and the terminal renders normally:** skip to Step 9.5 (no server changes needed).

**If errors appear:** continue to Step 9.3.

- [ ] **Step 9.3: Add COEP/COOP headers (only if needed)**

In `WebServer.swift`'s `HTTPHandler`, in the common "write response" helper (whatever function sets the default response headers), add:

```swift
response.headers.add(name: "Cross-Origin-Opener-Policy", value: "same-origin")
response.headers.add(name: "Cross-Origin-Embedder-Policy", value: "require-corp")
```

Add an integration test to `WebServerAuthTests.swift`:

```swift
@Test func httpResponsesIncludeCoopCoepHeaders() async throws {
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
        bindAddresses: ["127.0.0.1"]
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let (_, response) = try await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)/")!
    )
    let http = response as! HTTPURLResponse
    #expect(http.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy") == "same-origin")
    #expect(http.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy") == "require-corp")
}
```

Re-test in the browser to confirm the errors went away.

- [ ] **Step 9.4: Add SPECS requirement (only if headers were added)**

In `SPECS.md §15`, add **WEB-3.z**:

```
**WEB-3.z** The application shall respond to every HTTP request with
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` headers. wterm's WASM core
requires cross-origin isolation for SharedArrayBuffer.
```

- [ ] **Step 9.5: Commit if anything changed**

```bash
git add Sources/EspalierKit/Web/WebServer.swift Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift SPECS.md
git status
# if nothing is staged, skip the commit
git commit -m "feat(web): cross-origin isolation headers for wterm WASM SharedArrayBuffer"
```

---

## Task 10: Update SPECS.md §15 Web Access

Reflect all behavior changes.

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 10.1: Edit §15 per spec**

Open `SPECS.md`, find `## 15. Web Access`. Apply these textual changes:

- **WEB-3.1** body: replace with: "The application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client."
- **Insert new WEB-3.2 (renumber subsequent 3.x if needed):**
  ```
  **WEB-3.2** When a client requests any path that does not match a bundled
  static asset and does not begin with `/ws`, the application shall respond
  with the bundled `index.html` body and `Content-Type: text/html; charset=utf-8`.
  This serves the SPA fallback for client-side-routed URLs such as
  `/session/<name>`.
  ```
- **Insert new WEB-3.3:**
  ```
  **WEB-3.3** When a client requests `/wterm.wasm` (or any `.wasm` resource),
  the application shall respond with `Content-Type: application/wasm`.
  ```
- **WEB-5.1** body: replace with: "The bundled client shall render a single terminal (wterm) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility)."
- **WEB-5.2** body: replace with: "The client shall send terminal data events as binary WebSocket frames."

- [ ] **Step 10.2: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): update §15 Web Access for wterm + SPA fallback + path URLs"
```

---

## Task 11: Update README.md

Document the dev workflow.

**Files:**
- Modify: `README.md`

- [ ] **Step 11.1: Append "Developing the web client" section**

Add under the existing "Development" or equivalent section. If no such section exists, add one near the bottom above the license/footer:

```markdown
## Developing the web client

Espalier's browser-facing web access client lives in `web-client/` (React +
Vite + TypeScript + TanStack Router). If you change anything under
`web-client/`, rebuild the bundle that ships with the app:

```bash
./scripts/build-web.sh
```

This refreshes `Sources/EspalierKit/Web/Resources/{index.html,app.js,app.css,wterm.wasm}`.
CI verifies the committed bundle matches a fresh build.

You need `node` (LTS) and `pnpm` installed locally for web-client work:

```bash
brew install node pnpm
```

If you only touch Swift, you need neither — the committed bundle is what
`swift build` ships, and Homebrew users get the prebuilt tarball.
```

- [ ] **Step 11.2: Commit**

```bash
git add README.md
git commit -m "docs(readme): document web-client/ workflow and dev prerequisites"
```

---

## Task 12: Update CI to verify build-web.sh is reproducible

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 12.1: Read current CI config**

```bash
cat .github/workflows/ci.yml
```

- [ ] **Step 12.2: Add a job (or step) that runs build-web.sh and diffs**

Insert a step near the start of the existing macOS Swift job, before `swift test`:

```yaml
      - name: Install pnpm
        uses: pnpm/action-setup@v4
        with:
          version: 9

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
          cache-dependency-path: web-client/pnpm-lock.yaml

      - name: Verify web-client bundle is up to date
        run: |
          ./scripts/build-web.sh
          git diff --exit-code Sources/EspalierKit/Web/Resources/ \
            || { echo "::error::web-client/ changed but the committed bundle is stale. Run ./scripts/build-web.sh locally and recommit."; exit 1; }
```

Adjust action versions and exact placement to match the repo's existing patterns.

- [ ] **Step 12.3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: verify web-client bundle matches fresh build on every PR"
```

---

## Task 13: Update smoke checklist

**Files:**
- Modify: (create if missing) `docs/superpowers/plans/ZmxWebAccessSmokeChecklist.md`

- [ ] **Step 13.1: Locate the existing checklist**

```bash
find docs -name "*SmokeChecklist*" -o -name "*smoke-check*" 2>/dev/null
```

If none exists, create one at `docs/superpowers/plans/ZmxWebAccessSmokeChecklist.md` based on §Testing / End-to-end in `docs/superpowers/specs/2026-04-17-zmx-integration-phase-2-design.md`.

- [ ] **Step 13.2: Insert step 1.5**

After step 1 (the "open URL in Safari on phone; pane renders; type on phone/Mac; resize reflects") and before step 2 (the "from a Mac outside the tailnet, connection timeout") step, insert:

```markdown
### Step 1.5 — Native text selection (new for wterm)

In Safari on the phone, long-press a word of terminal output. A **native** iOS
text-selection handle should appear (not a canvas-rendered pseudo-selection).
Copy the selected text; paste into another app; confirm the bytes match what
was on screen. Validates the core UX reason for adopting wterm.
```

Also skim the rest of the checklist and update any URL mentions from `/?session=` to `/session/<name>` if relevant.

- [ ] **Step 13.3: Commit**

```bash
git add docs/superpowers/plans/ZmxWebAccessSmokeChecklist.md
git commit -m "docs(checklist): add native-text-selection smoke step; path URLs"
```

---

## Task 14: Final verification

- [ ] **Step 14.1: Clean rebuild of web-client to catch any drift**

```bash
rm -rf web-client/dist-tmp
./scripts/build-web.sh
git diff --stat Sources/EspalierKit/Web/Resources/
```

Expected: no diff. If there IS a diff, commit it.

- [ ] **Step 14.2: Full Swift test**

```bash
swift test 2>&1 | tail -40
```

Expected: all tests pass. Same skip set as before this PR.

- [ ] **Step 14.3: Manual smoke (tight loop)**

```bash
swift build
open .build/debug/Espalier  # or the correct launch path
```

Enable web access, open a pane, copy URL, open in Safari on the Mac (loopback), confirm:
- Terminal renders.
- Typing echoes.
- Text selection uses native handles.
- Resize reflects (`stty size` in the shell).

- [ ] **Step 14.4: Confirm no uncommitted files**

```bash
git status
```

Expected: clean tree on the `wterm` branch.

---

## Handoff

Plan complete. Execution: **subagent-driven**. Each task is self-contained; a fresh subagent per task is appropriate. Tasks 1, 4, 10, 11, 12, 13 are isolated and can run without dependencies on earlier tasks' code. Tasks 2, 3, 5, 6, 7, 8, 9, 14 depend on prior work and must run sequentially.

When all tasks complete, push the `wterm` branch and open a PR referencing:
- `docs/superpowers/specs/2026-04-19-wterm-adoption-design.md`
- This plan.

import { useEffect, useRef, useState } from 'react';
import { init, Terminal } from 'ghostty-web';

type Status = 'connecting' | 'reconnecting' | 'disconnected' | 'error' | string;

// ghostty-web's bundled FitAddon reserves 15px on the right for a native
// vertical scrollbar (proposeDimensions subtracts a hard-coded constant).
// Ghostty renders its scrollbar as a canvas overlay (not a DOM scrollbar),
// so those 15px would show up as an artificial gap and narrow the cols
// reported to the PTY — causing wrapping at e.g. 148 instead of 150.
// Fit ourselves against the host's full client area.
function fitTerminal(term: Terminal, host: HTMLElement): void {
  const metrics = term.renderer?.getMetrics();
  if (!metrics || metrics.width === 0 || metrics.height === 0) return;
  if (host.clientWidth === 0 || host.clientHeight === 0) return;
  const cols = Math.max(2, Math.floor(host.clientWidth / metrics.width));
  const rows = Math.max(1, Math.floor(host.clientHeight / metrics.height));
  if (cols !== term.cols || rows !== term.rows) term.resize(cols, rows);
}

const textEncoder = new TextEncoder();

// ghostty-web's `init()` loads the inlined WASM once into a process-wide
// Ghostty instance. Memoize the promise so parallel pane mounts don't race.
let ghosttyReady: Promise<void> | null = null;
function ensureGhostty() {
  if (!ghosttyReady) ghosttyReady = init();
  return ghosttyReady;
}

// WEB-5.6: reconnect backoff. 500ms → 1s → 2s → 4s → 8s cap. Jitter
// (±25%) stops multiple tabs re-opened in the same click from dog-
// piling the server on a shared-failure event. After a successful OPEN
// we reset to the first-attempt delay so the next drop uses a short
// initial timeout again.
function nextBackoffMs(attempt: number): number {
  const base = Math.min(500 * Math.pow(2, attempt), 8000);
  const jitter = base * 0.25 * (Math.random() * 2 - 1);
  return Math.max(250, Math.round(base + jitter));
}

export function TerminalPane({ sessionName }: { sessionName: string }) {
  const [status, setStatus] = useState<Status>('connecting');
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);

  useEffect(() => {
    let disposed = false;
    const host = hostRef.current;
    if (!host) return;

    // One AbortController cleans up every listener and observer this
    // effect registers — touch gestures, visualViewport tracking,
    // visibilitychange, the Terminal's ResizeObserver. The return fn
    // just calls `abort.abort()` and the browser removes them all.
    const abort = new AbortController();

    // Current websocket and reconnect bookkeeping — held in closure
    // variables (not React state) because they change on every
    // reconnect and would cause the effect to re-run if promoted to
    // state, tearing down the Terminal we want to keep alive.
    let currentWs: WebSocket | null = null;
    let attempt = 0;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let termReady = false;

    const wsUrl = (() => {
      const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      return `${proto}//${window.location.host}/ws?session=${encodeURIComponent(sessionName)}`;
    })();

    // Send `data` through whatever WebSocket is currently open. Called
    // by the Terminal's `onData` callback — that callback is bound
    // exactly once to the Terminal, so it captures `currentWs` by
    // closure and reads its up-to-date value on each keystroke. If the
    // socket is not OPEN (mid-reconnect), keystrokes are dropped
    // silently; the user sees "reconnecting…" in the status strip so
    // the drop is visible.
    const sendBytes = (data: string) => {
      if (currentWs && currentWs.readyState === WebSocket.OPEN) {
        currentWs.send(textEncoder.encode(data));
      }
    };

    const sendResize = (cols: number, rows: number) => {
      if (currentWs && currentWs.readyState === WebSocket.OPEN) {
        currentWs.send(JSON.stringify({ type: 'resize', cols, rows }));
      }
    };

    const connect = () => {
      if (disposed) return;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }

      const ws = new WebSocket(wsUrl);
      ws.binaryType = 'arraybuffer';
      currentWs = ws;

      ws.onopen = () => {
        attempt = 0;
        setStatus(sessionName);
        // Resend current dimensions on every (re)connect so the
        // fresh `zmx attach` child's PTY matches the terminal grid
        // — without this the server-side PTY defaults to 80x24 and
        // shell output would wrap wrong until the next resize.
        if (termReady && termRef.current) {
          sendResize(termRef.current.cols, termRef.current.rows);
        }
      };

      ws.onmessage = (ev) => {
        if (ev.data instanceof ArrayBuffer) {
          termRef.current?.write(new Uint8Array(ev.data));
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

      ws.onerror = () => {
        // Don't flip to 'error' — onclose will fire right after and
        // schedule a reconnect. Showing "error" then "reconnecting"
        // in rapid succession is just noise.
      };

      ws.onclose = () => {
        if (disposed) return;
        currentWs = null;
        setStatus('reconnecting');
        const delay = nextBackoffMs(attempt);
        attempt += 1;
        reconnectTimer = setTimeout(connect, delay);
      };
    };

    // Re-run immediately when the tab re-foregrounds, rather than
    // waiting out the current backoff. Mobile browsers freeze timers
    // on hidden tabs, so a pending setTimeout can be arbitrarily
    // delayed after the tab wakes; a user's first interaction should
    // feel responsive. Also handles the "OS suspended the WebSocket
    // while hidden; onclose hasn't fired yet" case — if currentWs is
    // not OPEN, we proactively close and re-open.
    const onVisibilityChange = () => {
      if (disposed) return;
      if (document.visibilityState !== 'visible') return;
      if (currentWs && currentWs.readyState === WebSocket.OPEN) return;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      // If there's a zombie socket in CONNECTING/CLOSING, kill it so
      // onclose fires and the new connect below is the only live one.
      if (currentWs && currentWs.readyState !== WebSocket.CLOSED) {
        try { currentWs.close(); } catch { /* already dead */ }
        currentWs = null;
      }
      attempt = 0;
      connect();
    };
    document.addEventListener('visibilitychange', onVisibilityChange, { signal: abort.signal });

    // WEB-5.7 mobile viewport tracking. When the software keyboard
    // opens, iOS/Android shrink `visualViewport.height` but leave
    // `window.innerHeight` alone — so a container sized to `100vh`
    // extends under the keyboard and the cursor row is hidden. Sizing
    // `host` to `visualViewport.{width,height}` (fallback
    // `window.inner{Width,Height}`) lets the existing ResizeObserver
    // refit the PTY rows so the cursor stays above the keyboard.
    // Width is tracked too: Android sometimes changes visual width
    // when the IME opens.
    const vv = window.visualViewport;
    let lastAppliedW = -1;
    let lastAppliedH = -1;
    const applyViewportSize = () => {
      if (disposed) return;
      const w = vv ? vv.width : window.innerWidth;
      const h = vv ? vv.height : window.innerHeight;
      // iOS fires `visualViewport.scroll` continuously during
      // momentum/IME animation — gate so we don't write the same px
      // into inline style dozens of times per second.
      if (w === lastAppliedW && h === lastAppliedH) return;
      lastAppliedW = w;
      lastAppliedH = h;
      host.style.width = `${w}px`;
      host.style.height = `${h}px`;
    };
    applyViewportSize();
    if (vv) {
      // `scroll` on visualViewport fires when iOS pans the viewport
      // around the keyboard without resizing — cover both.
      vv.addEventListener('resize', applyViewportSize, { signal: abort.signal });
      vv.addEventListener('scroll', applyViewportSize, { signal: abort.signal });
    }
    window.addEventListener('resize', applyViewportSize, { signal: abort.signal });

    ensureGhostty()
      .then(() => {
        if (disposed) return;
        const term = new Terminal({
          cols: 80,
          rows: 24,
          scrollback: 10000,
          fontSize: 14,
          fontFamily: 'Menlo, Consolas, "DejaVu Sans Mono", "Courier New", monospace',
          theme: {
            background: '#0d0d0d',
            foreground: '#e5e5e5',
          },
        });
        term.open(host);
        fitTerminal(term, host);
        const resizeObserver = new ResizeObserver(() => fitTerminal(term, host));
        resizeObserver.observe(host);
        abort.signal.addEventListener('abort', () => resizeObserver.disconnect());

        // WEB-5.7 touch scrollback. ghostty-web only handles wheel
        // events; mobile browsers produce wheel only for two-finger
        // trackpad-style scrolls, never for a single-finger drag on a
        // phone. Translate vertical single-finger drag here.
        // `scrollLines` is signed (positive=newer/down,
        // negative=older/up), so a finger-down drag (touchDelta>0 ⇒
        // user expects older content) maps to a negative line count
        // via the `-` in the call.
        //
        // Before committing to a scroll gesture, wait for ~1 cell of
        // movement so a short tap still reaches the terminal's focus
        // handler (which moves the hidden textarea under the finger
        // and focuses it to trigger the mobile keyboard). We use
        // `touchStartY === null` as the "committed" flag, so only two
        // variables — `touchStartY` (nulled on commit) and
        // `touchLastY` (updated every frame) — need to be tracked.
        // Multi-touch is ignored so pinch-zoom and two-finger gestures
        // aren't hijacked.
        let touchStartY: number | null = null;
        let touchLastY: number | null = null;
        // Char metrics only change on font/theme update, which doesn't
        // happen mid-drag; caching at touchstart avoids a WASM call
        // (and optional-chain allocation) on every touchmove frame.
        let touchCharHeight = 0;
        const onTouchStart = (ev: TouchEvent) => {
          if (ev.touches.length !== 1) { touchStartY = null; touchLastY = null; return; }
          touchStartY = ev.touches[0].clientY;
          touchLastY = touchStartY;
          touchCharHeight = term.renderer?.getMetrics()?.height ?? 0;
        };
        const onTouchMove = (ev: TouchEvent) => {
          if (touchLastY == null || ev.touches.length !== 1) return;
          if (touchCharHeight === 0) return;
          const y = ev.touches[0].clientY;
          if (touchStartY != null && Math.abs(y - touchStartY) < touchCharHeight) return;
          touchStartY = null;
          ev.preventDefault();
          term.scrollLines(-(y - touchLastY) / touchCharHeight);
          touchLastY = y;
        };
        const onTouchEnd = () => { touchStartY = null; touchLastY = null; };
        const signal = abort.signal;
        host.addEventListener('touchstart', onTouchStart, { passive: true, signal });
        host.addEventListener('touchmove', onTouchMove, { passive: false, signal });
        host.addEventListener('touchend', onTouchEnd, { signal });
        host.addEventListener('touchcancel', onTouchEnd, { signal });

        term.onData((data) => sendBytes(data));
        term.onResize(({ cols, rows }) => sendResize(cols, rows));

        termReady = true;
        termRef.current = term;
        term.focus();

        // fitTerminal already called resize() above, so onResize fired
        // synchronously. Push once more to cover the ws-not-yet-open
        // case: onopen will also call sendResize with the current
        // dimensions, but doing it here catches a ws that was already
        // OPEN by the time wasm finished loading.
        sendResize(term.cols, term.rows);
      })
      .catch((err) => {
        if (!disposed) setStatus(`wasm init failed: ${err?.message ?? err}`);
      });

    // Kick off the first connection in parallel with wasm init —
    // ghostty-web's init can take ~300ms on a cold load, and we
    // shouldn't lose that time off the socket handshake.
    connect();

    return () => {
      disposed = true;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      // Removes every listener and observer registered with
      // `{ signal: abort.signal }` or wired through
      // `abort.signal.addEventListener('abort', ...)`.
      abort.abort();
      if (currentWs) {
        currentWs.onclose = null;
        currentWs.close();
        currentWs = null;
      }
      termRef.current?.dispose();
      termRef.current = null;
    };
  }, [sessionName]);

  return (
    <>
      <div id="status">{status}</div>
      <div id="term" ref={hostRef} />
    </>
  );
}

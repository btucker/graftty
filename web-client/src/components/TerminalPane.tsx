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
    document.addEventListener('visibilitychange', onVisibilityChange);

    const abort = new AbortController();

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
      document.removeEventListener('visibilitychange', onVisibilityChange);
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
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

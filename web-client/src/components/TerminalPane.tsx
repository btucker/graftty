import { useEffect, useRef, useState } from 'react';
import { init, Terminal } from 'ghostty-web';

type Status = 'connecting' | 'reconnecting' | 'disconnected' | 'error' | string;
type DisplayClientKind = 'web' | 'mac' | 'ios' | 'preview';
type OwnershipSnapshot = {
  sessionName: string;
  ownerClientID: string | null;
  ownerKind: DisplayClientKind | null;
  grid: { cols: number; rows: number };
  epoch: number;
  ownerless: boolean;
};

const WEB_CLIENT_KIND: DisplayClientKind = 'web';
const MAX_PENDING_INPUT_BYTES = 1024 * 1024;
const MAX_PENDING_INPUT_FRAMES = 1024;

type PendingInputState = {
  frames: Uint8Array[];
  bytes: number;
  takeoverBaseEpoch: number | null;
  takeoverRequested: boolean;
};

// Mirrors the daemon's `DisplayGrid.daemonFallback` (Sources/GrafttyProtocol/
// DisplayOwnership.swift). Used before the terminal has measured itself or an
// ownership snapshot has arrived.
const DEFAULT_GRID = { cols: 80, rows: 24 };

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

function emptyPendingInputState(): PendingInputState {
  return {
    frames: [],
    bytes: 0,
    takeoverBaseEpoch: null,
    takeoverRequested: false,
  };
}

function generateWebClientID(): string {
  const randomID = globalThis.crypto?.randomUUID?.()
    ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  return `web-${randomID}`;
}

function parseOwnershipSnapshot(value: unknown): OwnershipSnapshot | null {
  if (!value || typeof value !== 'object') return null;
  const snapshot = value as Record<string, unknown>;
  const grid = snapshot.grid as Record<string, unknown> | undefined;
  if (!grid || typeof grid !== 'object') return null;
  if (typeof grid.cols !== 'number' || typeof grid.rows !== 'number') return null;
  if (typeof snapshot.sessionName !== 'string') return null;
  if (typeof snapshot.epoch !== 'number') return null;

  const ownerClientID = typeof snapshot.ownerClientID === 'string' ? snapshot.ownerClientID : null;
  const ownerKind = typeof snapshot.ownerKind === 'string' ? snapshot.ownerKind as DisplayClientKind : null;
  if ((ownerClientID == null) !== (ownerKind == null)) return null;

  return {
    sessionName: snapshot.sessionName,
    ownerClientID,
    ownerKind,
    grid: { cols: grid.cols, rows: grid.rows },
    epoch: snapshot.epoch,
    ownerless: typeof snapshot.ownerless === 'boolean' ? snapshot.ownerless : ownerClientID == null,
  };
}

// ghostty-web's `init()` loads the inlined WASM once into a process-wide
// Ghostty instance. Memoize the promise so parallel pane mounts don't race.
// Reset on rejection so a transient failure doesn't poison future mounts.
let ghosttyReady: Promise<void> | null = null;
function ensureGhostty() {
  if (!ghosttyReady) {
    ghosttyReady = init().catch((err) => { ghosttyReady = null; throw err; });
  }
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

interface TerminalPaneProps {
  sessionName: string;
  role?: 'interactive' | 'preview';
  fit?: 'viewport' | 'container';
  autoFocus?: boolean;
}

export function TerminalPane({ sessionName, role = 'interactive', fit = 'viewport', autoFocus = true }: TerminalPaneProps) {
  const [status, setStatus] = useState<Status>('connecting');
  const [activeClientID, setActiveClientID] = useState<string | null>(null);
  const [ownershipSnapshot, setOwnershipSnapshot] = useState<OwnershipSnapshot | null>(null);
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const connectionRef = useRef<{ ws: WebSocket | null; clientID: string | null }>({ ws: null, clientID: null });
  const ownershipRef = useRef<OwnershipSnapshot | null>(null);
  const isOwnerRef = useRef(false);
  const pendingInputRef = useRef<PendingInputState>(emptyPendingInputState());

  const isOwner = ownershipSnapshot?.ownerClientID === activeClientID
    && ownershipSnapshot?.ownerKind === WEB_CLIENT_KIND;
  const canTakeControl = ownershipSnapshot !== null && activeClientID !== null && !isOwner && role === 'interactive';

  const sendTakeControlFrame = () => {
    const { ws, clientID } = connectionRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN || !clientID) return false;
    const term = termRef.current;
    const fallbackGrid = ownershipRef.current?.grid;
    ws.send(JSON.stringify({
      type: 'takeControl',
      clientID,
      kind: WEB_CLIENT_KIND,
      cols: term?.cols ?? fallbackGrid?.cols ?? DEFAULT_GRID.cols,
      rows: term?.rows ?? fallbackGrid?.rows ?? DEFAULT_GRID.rows,
    }));
    return true;
  };

  const sendTakeControl = () => {
    sendTakeControlFrame();
  };

  useEffect(() => {
    let disposed = false;
    const host = hostRef.current;
    if (!host) return;
    const readOnly = role === 'preview';
    setStatus('connecting');
    setActiveClientID(null);
    setOwnershipSnapshot(null);
    connectionRef.current = { ws: null, clientID: null };
    ownershipRef.current = null;
    isOwnerRef.current = false;
    pendingInputRef.current = emptyPendingInputState();

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

    const currentGrid = () => {
      const term = termRef.current;
      if (term) return { cols: term.cols, rows: term.rows };
      return ownershipRef.current?.grid ?? DEFAULT_GRID;
    };

    const recomputeOwner = () => {
      const snapshot = ownershipRef.current;
      const clientID = connectionRef.current.clientID;
      isOwnerRef.current = Boolean(
        snapshot
          && clientID
          && snapshot.ownerClientID === clientID
          && snapshot.ownerKind === WEB_CLIENT_KIND,
      );
    };

    const setActiveConnection = (ws: WebSocket, clientID: string) => {
      connectionRef.current = { ws, clientID };
      setActiveClientID(clientID);
      recomputeOwner();
    };

    const clearActiveConnection = (ws: WebSocket) => {
      if (connectionRef.current.ws !== ws) return;
      connectionRef.current = { ws: null, clientID: null };
      setActiveClientID(null);
      recomputeOwner();
    };

    const sendHello = (ws: WebSocket, clientID: string) => {
      const { cols, rows } = currentGrid();
      ws.send(JSON.stringify({
        type: 'hello',
        clientID,
        kind: WEB_CLIENT_KIND,
        role,
        visible: true,
        cols,
        rows,
      }));
    };

    const clearPendingInput = () => {
      pendingInputRef.current = emptyPendingInputState();
    };

    const queuePendingInput = (data: Uint8Array) => {
      if (data.byteLength > MAX_PENDING_INPUT_BYTES) {
        clearPendingInput();
        return false;
      }
      if (
        pendingInputRef.current.frames.length >= MAX_PENDING_INPUT_FRAMES
        || pendingInputRef.current.bytes + data.byteLength > MAX_PENDING_INPUT_BYTES
      ) {
        clearPendingInput();
      }
      pendingInputRef.current.frames.push(data);
      pendingInputRef.current.bytes += data.byteLength;
      return true;
    };

    const requestTakeControlForPendingInput = () => {
      if (pendingInputRef.current.takeoverRequested) return;
      if (!sendTakeControlFrame()) return;
      pendingInputRef.current.takeoverBaseEpoch = ownershipRef.current?.epoch ?? null;
      pendingInputRef.current.takeoverRequested = true;
    };

    const flushPendingInput = () => {
      const { ws } = connectionRef.current;
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        clearPendingInput();
        return;
      }
      const pending = pendingInputRef.current.frames;
      clearPendingInput();
      for (const data of pending) {
        ws.send(data);
      }
    };

    // Send `data` through whatever WebSocket is currently open. Called
    // by the Terminal's `onData` callback — that callback is bound
    // exactly once to the Terminal, so it captures `currentWs` by
    // closure and reads its up-to-date value on each keystroke. If the
    // socket is not OPEN (mid-reconnect), keystrokes are dropped
    // silently; the user sees "reconnecting…" in the status strip so
    // the drop is visible.
    const sendBytes = (data: string) => {
      if (readOnly) return;
      const encoded = textEncoder.encode(data);
      if (isOwnerRef.current && currentWs && currentWs.readyState === WebSocket.OPEN) {
        currentWs.send(encoded);
        return;
      }
      if (!currentWs || currentWs.readyState !== WebSocket.OPEN) return;
      if (queuePendingInput(encoded)) requestTakeControlForPendingInput();
    };

    const sendOwnerResize = (cols: number, rows: number) => {
      if (readOnly) return;
      const clientID = connectionRef.current.clientID;
      const epoch = ownershipRef.current?.epoch;
      if (isOwnerRef.current && clientID && epoch != null && currentWs && currentWs.readyState === WebSocket.OPEN) {
        currentWs.send(JSON.stringify({ type: 'ownerResize', clientID, epoch, cols, rows }));
      }
    };

    const sendCurrentGridAsOwnerResize = () => {
      const { cols, rows } = currentGrid();
      sendOwnerResize(cols, rows);
    };

    const updateOwnership = (snapshot: OwnershipSnapshot) => {
      // Ignore reordered, stale broadcasts. The server enqueues sends from
      // multiple threads without ordering, so an older-epoch snapshot can
      // arrive after a newer one on the same socket; applying it would revert
      // the owner/grid we already advanced past. Strict `<` (not `<=`): the
      // server bumps `epoch` only on owner-identity changes, so legitimate
      // same-epoch grid resizes must still be applied.
      const prev = ownershipRef.current;
      if (prev && snapshot.epoch < prev.epoch) {
        return;
      }
      const wasOwner = isOwnerRef.current;
      ownershipRef.current = snapshot;
      recomputeOwner();
      setOwnershipSnapshot(snapshot);
      if (!wasOwner && isOwnerRef.current && termReady) {
        sendCurrentGridAsOwnerResize();
      }
      if (isOwnerRef.current) {
        flushPendingInput();
      } else if (
        pendingInputRef.current.takeoverBaseEpoch != null
        && snapshot.epoch > pendingInputRef.current.takeoverBaseEpoch
      ) {
        clearPendingInput();
      }
    };

    const connect = () => {
      if (disposed) return;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }

      const ws = new WebSocket(wsUrl);
      const clientID = generateWebClientID();
      ws.binaryType = 'arraybuffer';
      currentWs = ws;
      setActiveConnection(ws, clientID);

      const isCurrentSocket = () => currentWs === ws && connectionRef.current.ws === ws;

      ws.onopen = () => {
        if (!isCurrentSocket()) return;
        attempt = 0;
        setStatus(sessionName);
        sendHello(ws, clientID);
      };

      ws.onmessage = (ev) => {
        if (!isCurrentSocket()) return;
        if (ev.data instanceof ArrayBuffer) {
          const term = termRef.current;
          if (!term) return;
          const data = new Uint8Array(ev.data);
          // ghostty-web's write() calls scrollToBottom() whenever
          // viewportY !== 0, yanking the user out of scrollback on
          // every PTY chunk. When the user is scrolled up, save
          // viewportY, let write() run, then restore shifted by
          // scrollback growth so we pin the same absolute line rather
          // than the same offset-from-bottom. Skip on the alt screen
          // (vim/less): no scrollback, should stay at bottom.
          const savedViewportY = term.viewportY;
          if (savedViewportY === 0) {
            term.write(data);
            return;
          }
          const savedScrollbackLen = term.getScrollbackLength();
          const wasNormal = term.buffer.active.type === 'normal';
          term.write(data);
          if (wasNormal && term.buffer.active.type === 'normal') {
            const delta = term.getScrollbackLength() - savedScrollbackLen;
            term.scrollToLine(savedViewportY + delta);
          }
        } else {
          try {
            const msg = JSON.parse(String(ev.data));
            if (msg?.type === 'ownership') {
              const snapshot = parseOwnershipSnapshot(msg.snapshot);
              if (snapshot) updateOwnership(snapshot);
            } else if (msg?.type === 'error' || msg?.type === 'sessionEnded') {
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
        if (!isCurrentSocket()) return;
        currentWs = null;
        clearActiveConnection(ws);
        clearPendingInput();
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
    // When fit='container', skip this wiring — the host fills its parent
    // via CSS (width:100%;height:100%) and the ResizeObserver drives sizing.
    if (fit === 'viewport') {
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
    } else {
      host.style.width = '100%';
      host.style.height = '100%';
    }

    ensureGhostty()
      .then(() => {
        if (disposed) return;
        const term = new Terminal({
          cols: DEFAULT_GRID.cols,
          rows: DEFAULT_GRID.rows,
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
        term.onResize(({ cols, rows }) => sendOwnerResize(cols, rows));

        termReady = true;
        termRef.current = term;
        if (autoFocus) term.focus();

        // fitTerminal already called resize() above before onResize was
        // registered. If ownership was established while WASM loaded,
        // push the fitted grid now; otherwise the hello/snapshot flow
        // will establish ownership before later resizes are forwarded.
        sendOwnerResize(term.cols, term.rows);
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
      connectionRef.current = { ws: null, clientID: null };
      setActiveClientID(null);
      isOwnerRef.current = false;
      clearPendingInput();
      termRef.current?.dispose();
      termRef.current = null;
    };
  }, [sessionName, role, fit]);

  useEffect(() => {
    if (autoFocus) termRef.current?.focus();
  }, [autoFocus]);

  return (
    <>
      <div className="term-status">{status}</div>
      {canTakeControl ? (
        <button className="term-take-control" type="button" onClick={sendTakeControl}>
          Take Control
        </button>
      ) : null}
      <div className={fit === 'container' ? 'term-host term-host-container' : 'term-host'} ref={hostRef} />
    </>
  );
}

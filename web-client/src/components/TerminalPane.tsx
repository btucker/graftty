import { useEffect, useRef, useState } from 'react';
import { init, Terminal, FitAddon } from 'ghostty-web';

type Status = 'connecting' | 'disconnected' | 'error' | string;

// Shared across all TerminalPane instances: ghostty-web's `init()` loads the
// inlined WASM once and stores a process-wide Ghostty instance. Calling it
// multiple times from parallel pane mounts would race, so we memoize the promise.
let ghosttyReady: Promise<void> | null = null;
function ensureGhostty() {
  if (!ghosttyReady) ghosttyReady = init();
  return ghosttyReady;
}

export function TerminalPane({ sessionName }: { sessionName: string }) {
  const [status, setStatus] = useState<Status>('connecting');
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let disposed = false;
    const host = hostRef.current;
    if (!host) return;

    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(
      `${proto}//${window.location.host}/ws?session=${encodeURIComponent(sessionName)}`,
    );
    ws.binaryType = 'arraybuffer';
    wsRef.current = ws;

    ws.onopen = () => setStatus(sessionName);
    ws.onclose = () => setStatus('disconnected');
    ws.onerror = () => setStatus('error');

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
        const fit = new FitAddon();
        term.loadAddon(fit);
        fit.fit();
        fit.observeResize();

        term.onData((data) => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(new TextEncoder().encode(data));
          }
        });
        term.onResize(({ cols, rows }) => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'resize', cols, rows }));
          }
        });

        // Push initial size to the server so zmx spawns the PTY with the
        // terminal's actual dimensions (FitAddon runs before the first
        // onResize event that would normally carry this).
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
        } else {
          ws.addEventListener(
            'open',
            () =>
              ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows })),
            { once: true },
          );
        }

        ws.onmessage = (ev) => {
          if (ev.data instanceof ArrayBuffer) {
            term.write(new Uint8Array(ev.data));
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

        term.focus();
        termRef.current = term;
      })
      .catch((err) => {
        if (!disposed) setStatus(`wasm init failed: ${err?.message ?? err}`);
      });

    return () => {
      disposed = true;
      ws.close();
      wsRef.current = null;
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

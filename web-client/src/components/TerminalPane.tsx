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

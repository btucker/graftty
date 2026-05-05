import { readFileSync } from 'node:fs';
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { TerminalPane } from './TerminalPane';

const ghosttyMock = vi.hoisted(() => {
  const instances: any[] = [];

  class MockTerminal {
    cols: number;
    rows: number;
    viewportY = 0;
    buffer = { active: { type: 'normal' } };
    renderer = { getMetrics: vi.fn(() => ({ width: 8, height: 16 })) };
    dataHandler: ((data: string) => void) | null = null;
    resizeHandler: ((size: { cols: number; rows: number }) => void) | null = null;
    scrollbackLength = 0;
    nextScrollbackDelta = 0;
    open = vi.fn();
    focus = vi.fn();
    dispose = vi.fn();
    write = vi.fn(() => {
      this.scrollbackLength += this.nextScrollbackDelta;
      this.nextScrollbackDelta = 0;
    });
    scrollToLine = vi.fn((line: number) => {
      this.viewportY = line;
    });
    scrollLines = vi.fn();

    constructor(options: { cols: number; rows: number }) {
      this.cols = options.cols;
      this.rows = options.rows;
      instances.push(this);
    }

    resize(cols: number, rows: number) {
      this.cols = cols;
      this.rows = rows;
      this.resizeHandler?.({ cols, rows });
    }

    onData(handler: (data: string) => void) {
      this.dataHandler = handler;
    }

    onResize(handler: (size: { cols: number; rows: number }) => void) {
      this.resizeHandler = handler;
    }

    getScrollbackLength() {
      return this.scrollbackLength;
    }
  }

  function TerminalConstructor(this: unknown, options: { cols: number; rows: number }) {
    return new MockTerminal(options);
  }

  return {
    init: vi.fn(async () => {}),
    Terminal: vi.fn(TerminalConstructor),
    instances,
  };
});

vi.mock('ghostty-web', () => ({
  init: ghosttyMock.init,
  Terminal: ghosttyMock.Terminal,
}));

class MockWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances: MockWebSocket[] = [];

  readyState = MockWebSocket.CONNECTING;
  binaryType = '';
  sent: unknown[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(readonly url: string) {
    MockWebSocket.instances.push(this);
  }

  send(data: unknown) {
    this.sent.push(data);
  }

  open() {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  }

  receive(data: unknown) {
    this.onmessage?.({ data });
  }

  close() {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.();
  }
}

class MockResizeObserver {
  constructor(readonly callback: ResizeObserverCallback) {}
  observe = vi.fn();
  disconnect = vi.fn();
}

interface MockVisualViewport extends EventTarget {
  width: number;
  height: number;
}

let hostSize = { width: 800, height: 400 };
let visualViewport: MockVisualViewport | undefined;

beforeEach(() => {
  hostSize = { width: 800, height: 400 };
  ghosttyMock.instances.length = 0;
  ghosttyMock.init.mockClear();
  ghosttyMock.Terminal.mockClear();
  MockWebSocket.instances.length = 0;
  vi.stubGlobal('WebSocket', MockWebSocket);
  vi.stubGlobal('ResizeObserver', MockResizeObserver);
  Object.defineProperty(Element.prototype, 'clientWidth', {
    configurable: true,
    get() { return hostSize.width; },
  });
  Object.defineProperty(Element.prototype, 'clientHeight', {
    configurable: true,
    get() { return hostSize.height; },
  });
  visualViewport = undefined;
  Object.defineProperty(window, 'visualViewport', {
    configurable: true,
    value: undefined,
  });
  window.history.pushState({}, '', '/');
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

async function renderReady(sessionName = 'demo session') {
  render(<TerminalPane sessionName={sessionName} />);
  await waitFor(() => {
    expect(ghosttyMock.instances.length).toBe(1);
    expect(ghosttyMock.instances[0].dataHandler).toBeTruthy();
    expect(ghosttyMock.instances[0].resizeHandler).toBeTruthy();
  });
  return {
    term: ghosttyMock.instances[0],
    ws: MockWebSocket.instances[0],
    host: document.getElementById('term') as HTMLDivElement,
  };
}

function makeArrayBuffer(bytes: number[]) {
  return new window.Uint8Array(bytes).buffer;
}

function makeTouchEvent(type: string, y: number, touches = 1) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'touches', {
    value: touches === 1 ? [{ clientY: y }] : [],
  });
  return event;
}

function installVisualViewport(width: number, height: number) {
  visualViewport = Object.assign(new EventTarget(), { width, height });
  Object.defineProperty(window, 'visualViewport', {
    configurable: true,
    value: visualViewport,
  });
  return visualViewport;
}

// @spec WEB-5.1: The bundled client shall render a single terminal (ghostty-web, a WASM build of libghostty — the same VT parser as the native app pane) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility). Sharing a parser with the native pane is what keeps escape-sequence behavior (cursor movement, SGR state, OSC 8 hyperlinks, scrollback) identical across clients.
test('terminal pane constructs ghostty-web and connects to the encoded session websocket', async () => {
  const { term, ws } = await renderReady('demo session');

  expect(ghosttyMock.init).toHaveBeenCalledTimes(1);
  expect(ghosttyMock.Terminal).toHaveBeenCalledWith(expect.objectContaining({
    cols: 80,
    rows: 24,
    scrollback: 10000,
  }));
  expect(term.open).toHaveBeenCalledWith(document.getElementById('term'));
  expect(ws.url).toBe('ws://localhost:3000/ws?session=demo%20session');
  expect(ws.binaryType).toBe('arraybuffer');
});

// @spec WEB-5.2: The client shall send terminal data events as binary WebSocket frames.
test('terminal data events are sent as encoded bytes on the open websocket', async () => {
  const { term, ws } = await renderReady();

  await act(async () => ws.open());
  term.dataHandler?.('ls\n');

  const payload = ws.sent.at(-1);
  expect(ArrayBuffer.isView(payload)).toBe(true);
  expect(Array.from(payload as Uint8Array)).toEqual([108, 115, 10]);
});

// @spec WEB-5.3: The client shall send resize events as JSON control envelopes in text frames, including an initial resize sent on WebSocket open so the server-side PTY is sized to the client's actual viewport rather than the `zmx attach` default.
test('initial and later terminal sizes are sent as resize envelopes', async () => {
  hostSize = { width: 1200, height: 800 };
  const { term, ws } = await renderReady();

  await act(async () => ws.open());
  term.resizeHandler?.({ cols: 101, rows: 31 });

  expect(ws.sent).toEqual([
    JSON.stringify({ type: 'resize', cols: 150, rows: 50 }),
    JSON.stringify({ type: 'resize', cols: 101, rows: 31 }),
  ]);
});

// @spec WEB-5.5: The client shall size the terminal grid to fill the host element using the renderer's font metrics (`cols = floor(host.clientWidth / metrics.width)`, `rows = floor(host.clientHeight / metrics.height)`) and shall not reserve any horizontal pixels for a native scrollbar, so the canvas occupies the full viewport width and the PTY column count matches the visible grid. Rationale: ghostty-web's bundled `FitAddon` unconditionally subtracts 15 px from available width for a DOM scrollbar (`proposeDimensions()` in `ghostty-web.js`), but Ghostty renders its scrollback scrollbar as a canvas overlay — using `FitAddon` leaves a ~15 px gap on the right edge and narrows wrapping (e.g., 148 cols instead of 150 on a 1200 px viewport with 8 px cells).
test('terminal fit uses full host dimensions and renderer metrics', async () => {
  hostSize = { width: 1200, height: 800 };
  const { term } = await renderReady();

  expect(term.cols).toBe(150);
  expect(term.rows).toBe(50);
});

// @spec WEB-5.7: On mobile browsers the client shall (a) translate a single-finger vertical drag on the terminal host into `term.scrollLines(-deltaLines)` so scrollback is reachable without a hardware wheel (ghostty-web's built-in scrolling is wheel-only and mobile browsers do not synthesize wheel events from single-finger drag); and (b) size the terminal host to `window.visualViewport.{width,height}` (fallback `window.innerWidth/Height`), updating on `visualViewport` `resize` and `scroll` events, so when the software keyboard opens the host shrinks to the remaining visible area and the existing ResizeObserver refits `(cols, rows)` — keeping the cursor row above the keyboard rather than occluded beneath it. Taps shorter than one character-cell of movement shall still reach the terminal's own focus handler (which shows the mobile keyboard); multi-touch gestures (pinch, two-finger pan) shall pass through untouched. The terminal host shall declare `touch-action: none` and `overscroll-behavior: none` so the browser doesn't interpret the drag as page-scroll/pan/zoom or rubber-band the viewport before our handler sees the event.
test('terminal host follows visual viewport and maps touch drag to scrollback', async () => {
  const vv = installVisualViewport(390, 640);
  const { term, host } = await renderReady();

  expect(host.style.width).toBe('390px');
  expect(host.style.height).toBe('640px');

  vv.width = 320;
  vv.height = 300;
  vv.dispatchEvent(new Event('resize'));
  expect(host.style.width).toBe('320px');
  expect(host.style.height).toBe('300px');

  host.dispatchEvent(makeTouchEvent('touchstart', 100));
  host.dispatchEvent(makeTouchEvent('touchmove', 105));
  expect(term.scrollLines).not.toHaveBeenCalled();
  host.dispatchEvent(makeTouchEvent('touchmove', 132));
  expect(term.scrollLines).toHaveBeenCalledWith(-2);

  host.dispatchEvent(makeTouchEvent('touchstart', 200, 2));
  host.dispatchEvent(makeTouchEvent('touchmove', 240, 2));
  expect(term.scrollLines).toHaveBeenCalledTimes(1);
});

test('terminal host CSS disables browser touch panning and overscroll', async () => {
  const css = readFileSync('src/styles.css', 'utf8');

  expect(css).toMatch(/#term\s*{[^}]*touch-action:\s*none;/s);
  expect(css).toMatch(/#term\s*{[^}]*overscroll-behavior:\s*none;/s);
});

// @spec WEB-5.8: While the user is viewing scrollback on the normal screen (i.e., `term.viewportY > 0`), incoming PTY output shall not move the viewport: the client shall capture `viewportY` and scrollback length immediately before each `term.write()` call and, after the write, re-apply `viewportY` shifted by the number of lines that scrolled into scrollback so the viewport stays pinned to the same absolute content rather than the same offset-from-bottom. While the alternate screen is active on either side of the write, the viewport shall be left at the library-default bottom position. Rationale: ghostty-web's `Terminal.writeInternal` unconditionally calls `scrollToBottom()` whenever `viewportY !== 0` at write time, so without this wrapper the viewport snaps to the newest output on every WebSocket data frame — making wheel/touch scrollback unusable on any session that is actively producing output. Pinning to absolute content (not offset) is what lets the user read older lines while the shell continues to print.
test('incoming output pins normal-screen scrollback but not alternate screen', async () => {
  const { term, ws } = await renderReady();
  term.viewportY = 12;
  term.scrollbackLength = 40;
  term.nextScrollbackDelta = 3;

  await act(async () => ws.receive(makeArrayBuffer([65])));

  expect(term.write).toHaveBeenCalledWith(expect.any(Uint8Array));
  expect(term.scrollToLine).toHaveBeenCalledWith(15);

  term.scrollToLine.mockClear();
  term.viewportY = 7;
  term.scrollbackLength = 50;
  term.nextScrollbackDelta = 4;
  term.buffer.active.type = 'alternate';

  await act(async () => ws.receive(makeArrayBuffer([66])));

  expect(term.scrollToLine).not.toHaveBeenCalled();
});

test('server text status frames are rendered without writing terminal bytes', async () => {
  const { term, ws } = await renderReady();

  await act(async () => ws.receive(JSON.stringify({ type: 'sessionEnded', message: 'done' })));

  expect(await screen.findByText('done')).toBeTruthy();
  expect(term.write).not.toHaveBeenCalled();
});

# Web Pane Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the web UI into line with Mac & GrafttyMobile — a worktree-grouped selector, a GrafttyMobile-style live pane-layout overview at compact width, and a persistent sidebar + interactive Mac-style split layout at desktop width.

**Architecture:** Pure web-client (React 19 / TanStack Router) build with **zero backend change**. A responsive root branches on viewport width (mirroring mobile's `RootView`/`horizontalSizeClass`). It consumes the existing `GET /worktrees/panes` endpoint (`WorktreePanes[]` with a `PaneLayoutNode` split tree) and the existing `/ws?session=` + DisplayOwnership protocol already implemented in `TerminalPane.tsx`. One shared recursive `SplitLayout` renders the tree, parameterized by a `renderLeaf` callback (interactive terminal vs. live preview). Split dividers are a **read-only mirror** of the Mac's ratios in v1.

**Tech Stack:** React 19, TanStack Router 1.95, ghostty-web 0.4, TypeScript 5.7, Vitest 4 + @testing-library/react (jsdom).

## Global Constraints

- **No backend/protocol change.** v1 is web-client only. Do not add Swift control messages, endpoints, or wire types.
- **Read-only dividers.** Panes render at the Mac's ratios; dividers are not draggable. No web-side layout state, no `splitResize` message.
- **Preview panes must never claim ownership.** Preview terminals connect with `role: 'preview'` and never send `takeControl` or `ownerResize`. This is a tested invariant.
- **Desktop breakpoint = 900px** (`DESKTOP_MIN_WIDTH`), a single shared constant.
- **Wire model is authoritative.** TS types must match `Sources/GrafttyProtocol/WorktreePanes.swift` exactly: `PaneLayoutNode` uses a `"kind"` discriminator (`"leaf"` | `"split"`); leaf `isBusy` is **omitted when false**; `attentionText`/`attentionSource` optional. Worktree `layout` is `null` when no panes run.
- **Run web tests with:** `cd web-client && npm test` (Vitest, `vitest run`). Build check: `npm run build`.
- **Commit frequently** — one commit per task minimum, conventional-commit messages, ending with the Co-Authored-By trailer used in this repo.
- **@spec:** new behaviors get `WEB-9.x` EARS entries; no literal quotes in `@spec` titles (they truncate `SPECS.md`). Regenerate `SPECS.md` via `scripts/generate-specs.py` in the final task.

---

## File Structure

```
web-client/src/
  paneTypes.ts             TS mirror of WorktreePanes / PaneLayoutNode + parse/guards   (Task 1)
  panes/splitGeometry.ts   pure ratio→flex + leaf-collection functions                  (Task 2)
  panes/paneSizing.ts      pure previewFontSize()                                        (Task 7)
  hooks/useIsDesktop.ts    matchMedia(DESKTOP_MIN_WIDTH)                                 (Task 3)
  hooks/useWorktreePanes.ts poll /worktrees/panes, group by repo                        (Task 4)
  components/TerminalPane.tsx  refactor: role + fit + multi-instance safe               (Task 5)
  panes/SplitLayout.tsx    recursive geometry renderer, renderLeaf param                (Task 6)
  panes/PanePreview.tsx    read-only preview terminal (role=preview)                    (Task 7)
  panes/PaneOverview.tsx   SplitLayout + PanePreview leaves (compact)                   (Task 8)
  layout/Sidebar.tsx       grouped worktree list (Mac parity)                           (Task 9)
  layout/DesktopShell.tsx  Sidebar + interactive SplitLayout content + focus            (Task 10)
  layout/WorktreeListPage.tsx  compact full-page grouped list                           (Task 11)
  layout/AppRoot.tsx       width branch → DesktopShell | compact Outlet                 (Task 12)
  routes/worktree.$path.tsx  compact worktree detail (overview / redirect)              (Task 11)
  router.tsx, routes/__root.tsx, routes/index.tsx  re-pointed                           (Task 12)
Tests/GrafttyTests/Specs/WebTodo.swift  WEB-9.x inventory; SPECS.md regen               (Task 13)
```

Existing `routes/index.tsx` (`/sessions`-based flat picker) is superseded by the grouped worktree list; the `/sessions` endpoint stays untouched server-side.

---

### Task 1: TypeScript wire model (`paneTypes.ts`)

Mirror the `/worktrees/panes` JSON so every later task shares one typed shape and a defensive parser.

**Files:**
- Create: `web-client/src/paneTypes.ts`
- Test: `web-client/src/paneTypes.test.ts`

**Interfaces:**
- Produces:
  - `type PaneLayoutNode = PaneLeaf | PaneSplit`
  - `interface PaneLeaf { kind: 'leaf'; sessionName: string; title: string; attentionText: string | null; isBusy: boolean; attentionSource: AttentionSource | null }`
  - `interface PaneSplit { kind: 'split'; direction: 'horizontal' | 'vertical'; ratio: number; left: PaneLayoutNode; right: PaneLayoutNode }`
  - `type AttentionSource = 'agentStop' | 'userNotify' | 'commandFinished'`
  - `type WorktreeWireState = 'closed' | 'running' | 'stale' | 'creating' | 'deleting'`
  - `interface WorktreePanes { path: string; displayName: string; repoDisplayName: string; displayBranch: string; state: WorktreeWireState; isMainCheckout: boolean; prBadge: PRBadge | null; stats: WorktreeWireStats | null; attentionText: string | null; layout: PaneLayoutNode | null }`
  - `interface WorktreeWireStats { ahead: number; behind: number; hasUncommittedChanges: boolean; baseRef: string | null }`
  - `interface PRBadge { number: number; state: 'open' | 'merged' | 'closed'; checks: 'pending' | 'success' | 'failure' | 'none'; mergeable: 'mergeable' | 'conflicting' | 'unknown'; url: string }`
  - `function parseWorktreePanes(value: unknown): WorktreePanes[]` — tolerant: skips malformed entries, coerces missing optionals to `null`, missing `isBusy` to `false`, missing `state` to `'running'`.
  - `function paneLeaves(node: PaneLayoutNode | null): PaneLeaf[]` — in-order left→right leaf walk (mirrors Swift `PaneLayoutNode.leaves`).
  - `function displayTitle(leaf: PaneLeaf): string` — `leaf.title === '' ? 'shell' : leaf.title`.

- [ ] **Step 1: Write the failing test**

```ts
// web-client/src/paneTypes.test.ts
import { describe, it, expect } from 'vitest';
import { parseWorktreePanes, paneLeaves, displayTitle, type PaneLayoutNode } from './paneTypes';

const splitTree: PaneLayoutNode = {
  kind: 'split', direction: 'horizontal', ratio: 0.6,
  left: { kind: 'leaf', sessionName: 's1', title: 'bash', attentionText: null, isBusy: false, attentionSource: null },
  right: {
    kind: 'split', direction: 'vertical', ratio: 0.5,
    left: { kind: 'leaf', sessionName: 's2', title: '', attentionText: null, isBusy: true, attentionSource: null },
    right: { kind: 'leaf', sessionName: 's3', title: 'git', attentionText: 'done', isBusy: false, attentionSource: 'commandFinished' },
  },
};

describe('paneLeaves', () => {
  it('walks leaves left-to-right', () => {
    expect(paneLeaves(splitTree).map((l) => l.sessionName)).toEqual(['s1', 's2', 's3']);
  });
  it('returns [] for null layout', () => {
    expect(paneLeaves(null)).toEqual([]);
  });
});

describe('displayTitle', () => {
  it('falls back to "shell" for an empty title', () => {
    expect(displayTitle({ kind: 'leaf', sessionName: 's2', title: '', attentionText: null, isBusy: true, attentionSource: null })).toBe('shell');
  });
});

describe('parseWorktreePanes', () => {
  it('decodes the wire shape and coerces missing optionals', () => {
    const wire = [{
      path: '/wt/a', displayName: 'a', repoDisplayName: 'repo', displayBranch: 'main',
      state: 'running', isMainCheckout: true,
      layout: { kind: 'leaf', sessionName: 's1', title: 'bash' }, // isBusy/attentionText absent
    }];
    const [wt] = parseWorktreePanes(wire);
    expect(wt.path).toBe('/wt/a');
    expect(wt.prBadge).toBeNull();
    expect(wt.stats).toBeNull();
    const leaf = wt.layout as Extract<PaneLayoutNode, { kind: 'leaf' }>;
    expect(leaf.isBusy).toBe(false);
    expect(leaf.attentionText).toBeNull();
  });
  it('skips malformed entries instead of throwing', () => {
    expect(parseWorktreePanes([{ nonsense: true }, 42, null])).toEqual([]);
  });
  it('returns [] for non-array input', () => {
    expect(parseWorktreePanes({})).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/paneTypes.test.ts`
Expected: FAIL — `Cannot find module './paneTypes'`.

- [ ] **Step 3: Write minimal implementation**

```ts
// web-client/src/paneTypes.ts
export type AttentionSource = 'agentStop' | 'userNotify' | 'commandFinished';
export type WorktreeWireState = 'closed' | 'running' | 'stale' | 'creating' | 'deleting';

export interface PaneLeaf {
  kind: 'leaf';
  sessionName: string;
  title: string;
  attentionText: string | null;
  isBusy: boolean;
  attentionSource: AttentionSource | null;
}
export interface PaneSplit {
  kind: 'split';
  direction: 'horizontal' | 'vertical';
  ratio: number;
  left: PaneLayoutNode;
  right: PaneLayoutNode;
}
export type PaneLayoutNode = PaneLeaf | PaneSplit;

export interface PRBadge {
  number: number;
  state: 'open' | 'merged' | 'closed';
  checks: 'pending' | 'success' | 'failure' | 'none';
  mergeable: 'mergeable' | 'conflicting' | 'unknown';
  url: string;
}
export interface WorktreeWireStats {
  ahead: number;
  behind: number;
  hasUncommittedChanges: boolean;
  baseRef: string | null;
}
export interface WorktreePanes {
  path: string;
  displayName: string;
  repoDisplayName: string;
  displayBranch: string;
  state: WorktreeWireState;
  isMainCheckout: boolean;
  prBadge: PRBadge | null;
  stats: WorktreeWireStats | null;
  attentionText: string | null;
  layout: PaneLayoutNode | null;
}

const ATTENTION_SOURCES: AttentionSource[] = ['agentStop', 'userNotify', 'commandFinished'];
const WORKTREE_STATES: WorktreeWireState[] = ['closed', 'running', 'stale', 'creating', 'deleting'];

function str(v: unknown, fallback = ''): string { return typeof v === 'string' ? v : fallback; }
function strOrNull(v: unknown): string | null { return typeof v === 'string' ? v : null; }

function parseLayout(value: unknown): PaneLayoutNode | null {
  if (!value || typeof value !== 'object') return null;
  const o = value as Record<string, unknown>;
  if (o.kind === 'leaf') {
    if (typeof o.sessionName !== 'string') return null;
    const source = ATTENTION_SOURCES.includes(o.attentionSource as AttentionSource)
      ? (o.attentionSource as AttentionSource) : null;
    return {
      kind: 'leaf',
      sessionName: o.sessionName,
      title: str(o.title),
      attentionText: strOrNull(o.attentionText),
      isBusy: o.isBusy === true,
      attentionSource: source,
    };
  }
  if (o.kind === 'split') {
    const left = parseLayout(o.left);
    const right = parseLayout(o.right);
    if (!left || !right) return null;
    if (o.direction !== 'horizontal' && o.direction !== 'vertical') return null;
    if (typeof o.ratio !== 'number' || !Number.isFinite(o.ratio)) return null;
    return { kind: 'split', direction: o.direction, ratio: o.ratio, left, right };
  }
  return null;
}

function parsePRBadge(value: unknown): PRBadge | null {
  if (!value || typeof value !== 'object') return null;
  const o = value as Record<string, unknown>;
  if (typeof o.number !== 'number' || typeof o.url !== 'string') return null;
  return {
    number: o.number,
    state: (['open', 'merged', 'closed'].includes(o.state as string) ? o.state : 'open') as PRBadge['state'],
    checks: (['pending', 'success', 'failure', 'none'].includes(o.checks as string) ? o.checks : 'none') as PRBadge['checks'],
    mergeable: (['mergeable', 'conflicting', 'unknown'].includes(o.mergeable as string) ? o.mergeable : 'unknown') as PRBadge['mergeable'],
    url: o.url,
  };
}

function parseStats(value: unknown): WorktreeWireStats | null {
  if (!value || typeof value !== 'object') return null;
  const o = value as Record<string, unknown>;
  if (typeof o.ahead !== 'number' || typeof o.behind !== 'number') return null;
  return { ahead: o.ahead, behind: o.behind, hasUncommittedChanges: o.hasUncommittedChanges === true, baseRef: strOrNull(o.baseRef) };
}

function parseOne(value: unknown): WorktreePanes | null {
  if (!value || typeof value !== 'object') return null;
  const o = value as Record<string, unknown>;
  if (typeof o.path !== 'string' || typeof o.displayName !== 'string' || typeof o.repoDisplayName !== 'string') return null;
  return {
    path: o.path,
    displayName: o.displayName,
    repoDisplayName: o.repoDisplayName,
    displayBranch: str(o.displayBranch),
    state: (WORKTREE_STATES.includes(o.state as WorktreeWireState) ? o.state : 'running') as WorktreeWireState,
    isMainCheckout: o.isMainCheckout === true,
    prBadge: parsePRBadge(o.prBadge),
    stats: parseStats(o.stats),
    attentionText: strOrNull(o.attentionText),
    layout: parseLayout(o.layout),
  };
}

export function parseWorktreePanes(value: unknown): WorktreePanes[] {
  if (!Array.isArray(value)) return [];
  const out: WorktreePanes[] = [];
  for (const entry of value) {
    const parsed = parseOne(entry);
    if (parsed) out.push(parsed);
  }
  return out;
}

export function paneLeaves(node: PaneLayoutNode | null): PaneLeaf[] {
  if (!node) return [];
  if (node.kind === 'leaf') return [node];
  return [...paneLeaves(node.left), ...paneLeaves(node.right)];
}

export function displayTitle(leaf: PaneLeaf): string {
  return leaf.title === '' ? 'shell' : leaf.title;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/paneTypes.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add web-client/src/paneTypes.ts web-client/src/paneTypes.test.ts
git commit -m "feat(web): typed /worktrees/panes wire model + tolerant parser

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Split geometry pure functions (`splitGeometry.ts`)

The DOM-free ratio math the `SplitLayout` renderer will use — the natural TDD seam.

**Files:**
- Create: `web-client/src/panes/splitGeometry.ts`
- Test: `web-client/src/panes/splitGeometry.test.ts`

**Interfaces:**
- Consumes: `PaneLayoutNode` from `../paneTypes`.
- Produces:
  - `function flexBasisForRatio(ratio: number): { left: number; right: number }` — clamps ratio to `[0.05, 0.95]`, returns `{ left: clamped, right: 1 - clamped }` (used as `flex-grow` values).
  - `function flexDirectionFor(direction: 'horizontal' | 'vertical'): 'row' | 'column'` — `horizontal → 'row'`, `vertical → 'column'`.
  - `function leafCount(node: PaneLayoutNode | null): number`.

- [ ] **Step 1: Write the failing test**

```ts
// web-client/src/panes/splitGeometry.test.ts
import { describe, it, expect } from 'vitest';
import { flexBasisForRatio, flexDirectionFor, leafCount } from './splitGeometry';
import type { PaneLayoutNode } from '../paneTypes';

describe('flexBasisForRatio', () => {
  it('splits proportionally', () => {
    expect(flexBasisForRatio(0.6)).toEqual({ left: 0.6, right: 0.4 });
  });
  it('clamps degenerate ratios so no pane collapses to zero', () => {
    expect(flexBasisForRatio(0)).toEqual({ left: 0.05, right: 0.95 });
    expect(flexBasisForRatio(1)).toEqual({ left: 0.95, right: 0.05 });
  });
});

describe('flexDirectionFor', () => {
  it('maps horizontal splits to a row (side-by-side)', () => {
    expect(flexDirectionFor('horizontal')).toBe('row');
    expect(flexDirectionFor('vertical')).toBe('column');
  });
});

describe('leafCount', () => {
  it('counts leaves in the tree', () => {
    const tree: PaneLayoutNode = {
      kind: 'split', direction: 'horizontal', ratio: 0.5,
      left: { kind: 'leaf', sessionName: 'a', title: '', attentionText: null, isBusy: false, attentionSource: null },
      right: { kind: 'leaf', sessionName: 'b', title: '', attentionText: null, isBusy: false, attentionSource: null },
    };
    expect(leafCount(tree)).toBe(2);
    expect(leafCount(null)).toBe(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/panes/splitGeometry.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// web-client/src/panes/splitGeometry.ts
import type { PaneLayoutNode } from '../paneTypes';

const MIN_RATIO = 0.05;
const MAX_RATIO = 0.95;

export function flexBasisForRatio(ratio: number): { left: number; right: number } {
  const clamped = Math.min(MAX_RATIO, Math.max(MIN_RATIO, ratio));
  return { left: clamped, right: 1 - clamped };
}

export function flexDirectionFor(direction: 'horizontal' | 'vertical'): 'row' | 'column' {
  return direction === 'horizontal' ? 'row' : 'column';
}

export function leafCount(node: PaneLayoutNode | null): number {
  if (!node) return 0;
  if (node.kind === 'leaf') return 1;
  return leafCount(node.left) + leafCount(node.right);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/panes/splitGeometry.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/panes/splitGeometry.ts web-client/src/panes/splitGeometry.test.ts
git commit -m "feat(web): pure split-geometry helpers for the pane layout renderer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `useIsDesktop` hook

Width branch on a shared 900px breakpoint via `matchMedia`.

**Files:**
- Create: `web-client/src/hooks/useIsDesktop.ts`
- Test: `web-client/src/hooks/useIsDesktop.test.tsx`

**Interfaces:**
- Produces:
  - `const DESKTOP_MIN_WIDTH = 900`
  - `function useIsDesktop(): boolean` — `true` while `window.matchMedia('(min-width: 900px)')` matches; subscribes to changes.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/hooks/useIsDesktop.test.tsx
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useIsDesktop, DESKTOP_MIN_WIDTH } from './useIsDesktop';

function installMatchMedia(initialMatches: boolean) {
  let listener: ((e: MediaQueryListEvent) => void) | null = null;
  const mql = {
    matches: initialMatches,
    media: `(min-width: ${DESKTOP_MIN_WIDTH}px)`,
    addEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => { listener = cb; },
    removeEventListener: () => { listener = null; },
  };
  vi.stubGlobal('matchMedia', () => mql);
  return {
    emit(matches: boolean) {
      mql.matches = matches;
      listener?.({ matches } as MediaQueryListEvent);
    },
  };
}

describe('useIsDesktop', () => {
  beforeEach(() => vi.unstubAllGlobals());

  it('reflects the initial match', () => {
    installMatchMedia(true);
    const { result } = renderHook(() => useIsDesktop());
    expect(result.current).toBe(true);
  });

  it('updates when the media query changes', () => {
    const mm = installMatchMedia(false);
    const { result } = renderHook(() => useIsDesktop());
    expect(result.current).toBe(false);
    act(() => mm.emit(true));
    expect(result.current).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/hooks/useIsDesktop.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// web-client/src/hooks/useIsDesktop.ts
import { useEffect, useState } from 'react';

export const DESKTOP_MIN_WIDTH = 900;

export function useIsDesktop(): boolean {
  const query = `(min-width: ${DESKTOP_MIN_WIDTH}px)`;
  const [isDesktop, setIsDesktop] = useState<boolean>(() =>
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia(query).matches
      : false,
  );

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mql = window.matchMedia(query);
    const onChange = (e: MediaQueryListEvent) => setIsDesktop(e.matches);
    setIsDesktop(mql.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, [query]);

  return isDesktop;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/hooks/useIsDesktop.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/hooks/useIsDesktop.ts web-client/src/hooks/useIsDesktop.test.tsx
git commit -m "feat(web): useIsDesktop width-branch hook (900px breakpoint)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `useWorktreePanes` hook (poll + group)

Fetch `/worktrees/panes`, parse, group by repo, and re-poll on an interval.

**Files:**
- Create: `web-client/src/hooks/useWorktreePanes.ts`
- Test: `web-client/src/hooks/useWorktreePanes.test.tsx`

**Interfaces:**
- Consumes: `parseWorktreePanes`, `WorktreePanes` from `../paneTypes`.
- Produces:
  - `interface RepoGroup { repoDisplayName: string; worktrees: WorktreePanes[] }`
  - `function groupByRepo(worktrees: WorktreePanes[]): RepoGroup[]` — stable insertion order of first appearance (pure, exported for direct testing).
  - `type WorktreePanesState = { kind: 'loading' } | { kind: 'error'; message: string } | { kind: 'ready'; groups: RepoGroup[]; worktrees: WorktreePanes[] }`
  - `function useWorktreePanes(pollMs?: number): WorktreePanesState` — default `pollMs = 2000`. Fetches immediately, then every `pollMs`. Keeps last-good data across a failed poll (only surfaces `error` before the first success).

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/hooks/useWorktreePanes.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { waitFor, renderHook } from '@testing-library/react';
import { groupByRepo, useWorktreePanes } from './useWorktreePanes';
import type { WorktreePanes } from '../paneTypes';

const wt = (path: string, repo: string): WorktreePanes => ({
  path, displayName: path, repoDisplayName: repo, displayBranch: 'main',
  state: 'running', isMainCheckout: false, prBadge: null, stats: null, attentionText: null, layout: null,
});

describe('groupByRepo', () => {
  it('groups worktrees under their repo in first-seen order', () => {
    const groups = groupByRepo([wt('/a', 'r1'), wt('/b', 'r2'), wt('/c', 'r1')]);
    expect(groups.map((g) => g.repoDisplayName)).toEqual(['r1', 'r2']);
    expect(groups[0].worktrees.map((w) => w.path)).toEqual(['/a', '/c']);
  });
});

describe('useWorktreePanes', () => {
  it('fetches and exposes grouped worktrees', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: true,
      json: async () => [wt('/a', 'r1')],
    })) as unknown as typeof fetch);
    const { result } = renderHook(() => useWorktreePanes(10_000));
    await waitFor(() => expect(result.current.kind).toBe('ready'));
    if (result.current.kind === 'ready') {
      expect(result.current.groups[0].repoDisplayName).toBe('r1');
    }
    vi.unstubAllGlobals();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/hooks/useWorktreePanes.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// web-client/src/hooks/useWorktreePanes.ts
import { useEffect, useRef, useState } from 'react';
import { parseWorktreePanes, type WorktreePanes } from '../paneTypes';

export interface RepoGroup {
  repoDisplayName: string;
  worktrees: WorktreePanes[];
}

export type WorktreePanesState =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; groups: RepoGroup[]; worktrees: WorktreePanes[] };

export function groupByRepo(worktrees: WorktreePanes[]): RepoGroup[] {
  const order: string[] = [];
  const byRepo = new Map<string, WorktreePanes[]>();
  for (const wt of worktrees) {
    const key = wt.repoDisplayName;
    if (!byRepo.has(key)) { byRepo.set(key, []); order.push(key); }
    byRepo.get(key)!.push(wt);
  }
  return order.map((repoDisplayName) => ({ repoDisplayName, worktrees: byRepo.get(repoDisplayName)! }));
}

export function useWorktreePanes(pollMs = 2000): WorktreePanesState {
  const [state, setState] = useState<WorktreePanesState>({ kind: 'loading' });
  const haveDataRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    const poll = async () => {
      try {
        const res = await fetch('/worktrees/panes', { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`/worktrees/panes → ${res.status}`);
        const worktrees = parseWorktreePanes(await res.json());
        if (cancelled) return;
        haveDataRef.current = true;
        setState({ kind: 'ready', groups: groupByRepo(worktrees), worktrees });
      } catch (err) {
        if (cancelled || haveDataRef.current) return; // keep last-good data
        setState({ kind: 'error', message: err instanceof Error ? err.message : String(err) });
      }
    };
    void poll();
    const timer = setInterval(poll, pollMs);
    return () => { cancelled = true; clearInterval(timer); };
  }, [pollMs]);

  return state;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/hooks/useWorktreePanes.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/hooks/useWorktreePanes.ts web-client/src/hooks/useWorktreePanes.test.tsx
git commit -m "feat(web): useWorktreePanes polling hook + repo grouping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Make `TerminalPane` multi-instance safe + role/fit props

`TerminalPane` currently assumes a single instance (fixed `id="term"`/`id="status"`/`id="take-control"`) and force-sizes its host to the whole visual viewport. Both break inside a split. Parameterize it.

**Files:**
- Modify: `web-client/src/components/TerminalPane.tsx`
- Test: `web-client/src/components/TerminalPane.test.tsx` (extend)

**Interfaces:**
- Produces (new prop contract):
  - `interface TerminalPaneProps { sessionName: string; role?: 'interactive' | 'preview'; fit?: 'viewport' | 'container'; autoFocus?: boolean }`
  - Defaults preserve today's behavior: `role='interactive'`, `fit='viewport'`, `autoFocus=true`.
  - Behavior when `role='preview'`: `sendHello` sends `role: 'preview'`; `sendBytes` is a no-op (never writes input, never queues, never requests take-control); the Take Control button never renders; `sendOwnerResize` is a no-op.
  - Behavior when `fit='container'`: the `applyViewportSize`/visualViewport wiring is skipped; the host fills its parent (`width:100%;height:100%`) and the existing `ResizeObserver`+`fitTerminal` drive cols/rows from the host's own box.
  - DOM: replace `id="term"` / `id="status"` / `id="take-control"` with `className` equivalents (`term-host` / `term-status` / `term-take-control`) so multiple instances don't collide. Keep the same visual styling via the class in `styles.css` (Task adds the classes).

**Notes for implementer:**
- Guard the ownership/input paths on a `role === 'preview'` check computed once inside the effect (capture `const readOnly = role === 'preview'`).
- In `sendBytes`, early-return when `readOnly`.
- In `sendOwnerResize`, early-return when `readOnly` (a preview must never claim/resize).
- Still connect the WebSocket and still `sendHello` (so the server registers a `preview` viewer and streams PTY bytes for the live preview).
- Do not call `term.focus()` when `autoFocus === false`.
- Keep the CSS-id → CSS-class rename consistent with `styles.css`; do not leave any `id="term"` references.

- [ ] **Step 1: Write the failing test**

```tsx
// add to web-client/src/components/TerminalPane.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import { TerminalPane } from './TerminalPane';

// A minimal WebSocket capture so we can assert on the hello frame.
class FakeWS {
  static instances: FakeWS[] = [];
  url: string; readyState = 0; binaryType = 'arraybuffer';
  sent: string[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  constructor(url: string) { this.url = url; FakeWS.instances.push(this); }
  send(data: unknown) { if (typeof data === 'string') this.sent.push(data); }
  close() { this.readyState = 3; }
  open() { this.readyState = 1; this.onopen?.(); }
}

afterEach(() => { cleanup(); FakeWS.instances = []; vi.unstubAllGlobals(); });

describe('@spec WEB-9.5 preview role', () => {
  it('sends a preview-role hello and never a takeControl or ownerResize frame', async () => {
    vi.stubGlobal('WebSocket', FakeWS as unknown as typeof WebSocket);
    render(<TerminalPane sessionName="s1" role="preview" fit="container" autoFocus={false} />);
    // Wait a microtask for the effect to open the socket.
    await Promise.resolve();
    const ws = FakeWS.instances[0];
    expect(ws).toBeTruthy();
    ws.open();
    const hello = ws.sent.map((s) => JSON.parse(s)).find((m) => m.type === 'hello');
    expect(hello.role).toBe('preview');
    // Even after a simulated ownership snapshot naming another owner, no claim is sent.
    ws.onmessage?.({ data: JSON.stringify({ type: 'ownership', snapshot: {
      sessionName: 's1', ownerClientID: 'mac-1', ownerKind: 'mac', grid: { cols: 80, rows: 24 }, epoch: 1, ownerless: false,
    } }) } as MessageEvent);
    expect(ws.sent.map((s) => JSON.parse(s)).some((m) => m.type === 'takeControl' || m.type === 'ownerResize')).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/components/TerminalPane.test.tsx -t "WEB-9.5"`
Expected: FAIL — `TerminalPane` rejects the extra props / sends `role:'interactive'` / would attempt claims. (If ghostty-web `init()` needs stubbing under jsdom, mock it at the top of the test file the same way the existing tests in this file do; follow the established pattern already present.)

- [ ] **Step 3: Implement the prop changes**

Apply these edits to `TerminalPane.tsx`:
1. Change the signature to `export function TerminalPane({ sessionName, role = 'interactive', fit = 'viewport', autoFocus = true }: TerminalPaneProps)` and add the `TerminalPaneProps` interface above.
2. Inside the effect add `const readOnly = role === 'preview';`.
3. In `sendHello`, replace the hardcoded `role: 'interactive'` with `role,`.
4. In `sendBytes`, add `if (readOnly) return;` as the first line.
5. In `sendOwnerResize`, add `if (readOnly) return;` as the first line.
6. Wrap the `visualViewport` / `applyViewportSize` / `window resize` block in `if (fit === 'viewport') { … }`. In the `else` branch set `host.style.width = '100%'; host.style.height = '100%';` once.
7. Replace `term.focus();` with `if (autoFocus) term.focus();`.
8. Rename the three DOM `id=` attributes to `className=` (`term-status`, `term-take-control`, `term-host`). Update `styles.css` selectors `#status`/`#term`/`#take-control` → `.term-status`/`.term-host`/`.term-take-control` (keep declarations identical). The `canTakeControl` gate additionally requires `role === 'interactive'`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web-client && npx vitest run src/components/TerminalPane.test.tsx`
Expected: PASS — the new WEB-9.5 test and all pre-existing TerminalPane tests still green.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/components/TerminalPane.tsx web-client/src/components/TerminalPane.test.tsx web-client/src/styles.css
git commit -m "refactor(web): TerminalPane role/fit props + multi-instance-safe DOM (WEB-9.5)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `SplitLayout` recursive renderer

Renders a `PaneLayoutNode` as nested flexboxes with fixed dividers; leaves are delegated to a `renderLeaf` callback so the same geometry serves interactive and preview modes.

**Files:**
- Create: `web-client/src/panes/SplitLayout.tsx`
- Test: `web-client/src/panes/SplitLayout.test.tsx`

**Interfaces:**
- Consumes: `PaneLayoutNode`, `PaneLeaf` from `../paneTypes`; `flexBasisForRatio`, `flexDirectionFor` from `./splitGeometry`.
- Produces:
  - `interface SplitLayoutProps { node: PaneLayoutNode; renderLeaf: (leaf: PaneLeaf) => React.ReactNode }`
  - `function SplitLayout(props: SplitLayoutProps): JSX.Element` — a `split` renders a flex container (`flexDirection` from `flexDirectionFor`) with two children carrying `flexGrow` from `flexBasisForRatio` and a `<div className="split-divider" data-direction=…>` between them; a `leaf` renders `<div className="pane-slot" data-session={leaf.sessionName}>{renderLeaf(leaf)}</div>`.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/panes/SplitLayout.test.tsx
import { describe, it, expect, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';
import { SplitLayout } from './SplitLayout';
import type { PaneLayoutNode, PaneLeaf } from '../paneTypes';

afterEach(cleanup);

const leaf = (s: string): PaneLeaf => ({ kind: 'leaf', sessionName: s, title: s, attentionText: null, isBusy: false, attentionSource: null });

describe('@spec WEB-9.2 SplitLayout', () => {
  it('renders one pane slot per leaf in order', () => {
    const tree: PaneLayoutNode = { kind: 'split', direction: 'horizontal', ratio: 0.6, left: leaf('a'), right: leaf('b') };
    render(<SplitLayout node={tree} renderLeaf={(l) => <span>{l.sessionName}</span>} />);
    const slots = screen.getAllByTestId('pane-slot');
    expect(slots.map((s) => s.getAttribute('data-session'))).toEqual(['a', 'b']);
  });

  it('maps horizontal splits to flex-direction row with proportional grow', () => {
    const tree: PaneLayoutNode = { kind: 'split', direction: 'horizontal', ratio: 0.6, left: leaf('a'), right: leaf('b') };
    render(<SplitLayout node={tree} renderLeaf={(l) => <span>{l.sessionName}</span>} />);
    const container = screen.getByTestId('split-container');
    expect(container.style.flexDirection).toBe('row');
    const [left, right] = screen.getAllByTestId('split-child');
    expect(left.style.flexGrow).toBe('0.6');
    expect(right.style.flexGrow).toBe('0.4');
  });

  it('renders a single leaf with no divider', () => {
    render(<SplitLayout node={leaf('solo')} renderLeaf={(l) => <span>{l.sessionName}</span>} />);
    expect(screen.getAllByTestId('pane-slot')).toHaveLength(1);
    expect(screen.queryByTestId('split-divider')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/panes/SplitLayout.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```tsx
// web-client/src/panes/SplitLayout.tsx
import type { ReactNode } from 'react';
import type { PaneLayoutNode, PaneLeaf } from '../paneTypes';
import { flexBasisForRatio, flexDirectionFor } from './splitGeometry';

export interface SplitLayoutProps {
  node: PaneLayoutNode;
  renderLeaf: (leaf: PaneLeaf) => ReactNode;
}

export function SplitLayout({ node, renderLeaf }: SplitLayoutProps) {
  if (node.kind === 'leaf') {
    return (
      <div className="pane-slot" data-testid="pane-slot" data-session={node.sessionName}
           style={{ width: '100%', height: '100%', position: 'relative' }}>
        {renderLeaf(node)}
      </div>
    );
  }
  const basis = flexBasisForRatio(node.ratio);
  const direction = flexDirectionFor(node.direction);
  return (
    <div className="split-container" data-testid="split-container"
         style={{ display: 'flex', flexDirection: direction, width: '100%', height: '100%' }}>
      <div className="split-child" data-testid="split-child"
           style={{ flexGrow: basis.left, flexBasis: 0, minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
        <SplitLayout node={node.left} renderLeaf={renderLeaf} />
      </div>
      <div className="split-divider" data-testid="split-divider" data-direction={node.direction} />
      <div className="split-child" data-testid="split-child"
           style={{ flexGrow: basis.right, flexBasis: 0, minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
        <SplitLayout node={node.right} renderLeaf={renderLeaf} />
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/panes/SplitLayout.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/panes/SplitLayout.tsx web-client/src/panes/SplitLayout.test.tsx
git commit -m "feat(web): recursive SplitLayout renderer with fixed dividers (WEB-9.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `PanePreview` + `previewFontSize`

A live, read-only preview tile: a `role='preview'` `TerminalPane` in container-fit mode, with a title overlay, that navigates to the fullscreen session on click. The font-fit math is a pure function.

**Files:**
- Create: `web-client/src/panes/paneSizing.ts`
- Create: `web-client/src/panes/paneSizing.test.ts`
- Create: `web-client/src/panes/PanePreview.tsx`
- Create: `web-client/src/panes/PanePreview.test.tsx`

**Interfaces:**
- Consumes: `PaneLeaf`, `displayTitle` from `../paneTypes`; `TerminalPane` from `../components/TerminalPane`; `useNavigate` from `@tanstack/react-router`.
- Produces:
  - `function previewFontSize(opts: { tileWidth: number; targetCols: number; cellWidthRatio?: number }): number` — returns `clamp(tileWidth / (targetCols * cellWidthRatio), 6, 14)`, default `cellWidthRatio = 0.6`, default via caller `targetCols = 80`. Guards non-finite/≤0 inputs by returning the 6px floor.
  - `interface PanePreviewProps { leaf: PaneLeaf }`
  - `function PanePreview({ leaf }: PanePreviewProps): JSX.Element` — renders a tile: a `<TerminalPane sessionName={leaf.sessionName} role="preview" fit="container" autoFocus={false} />` plus a `<div className="pane-preview-title">{displayTitle(leaf)}</div>` overlay, wrapped in a button/clickable that calls `navigate({ to: '/session/$name', params: { name: leaf.sessionName } })`.

**Note:** For v1, `previewFontSize` is applied via CSS `--preview-font-size` on the tile (the terminal reads container size to fit; the pure fn exists to keep the sizing intent testable and ready for a future direct-font wiring). Keep the fn and its unit test; wire the CSS var on the tile from a `ResizeObserver`-measured width or a sensible default (e.g. `previewFontSize({ tileWidth: host.clientWidth, targetCols: 80 })`).

- [ ] **Step 1: Write the failing tests**

```ts
// web-client/src/panes/paneSizing.test.ts
import { describe, it, expect } from 'vitest';
import { previewFontSize } from './paneSizing';

describe('previewFontSize', () => {
  it('sizes the font so ~targetCols columns fit the tile width', () => {
    // 300px / (80 * 0.6) = 6.25 → within [6,14]
    expect(previewFontSize({ tileWidth: 300, targetCols: 80 })).toBeCloseTo(6.25, 2);
  });
  it('clamps to the 14px ceiling for wide tiles', () => {
    expect(previewFontSize({ tileWidth: 5000, targetCols: 80 })).toBe(14);
  });
  it('returns the 6px floor for degenerate input', () => {
    expect(previewFontSize({ tileWidth: 0, targetCols: 80 })).toBe(6);
    expect(previewFontSize({ tileWidth: NaN, targetCols: 80 })).toBe(6);
  });
});
```

```tsx
// web-client/src/panes/PanePreview.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';
import type { PaneLeaf } from '../paneTypes';

const navigate = vi.fn();
vi.mock('@tanstack/react-router', () => ({ useNavigate: () => navigate }));
// Stub TerminalPane so the preview test doesn't boot ghostty-web/WASM.
vi.mock('../components/TerminalPane', () => ({
  TerminalPane: (props: { sessionName: string; role?: string }) =>
    <div data-testid="terminal-pane" data-session={props.sessionName} data-role={props.role} />,
}));

import { PanePreview } from './PanePreview';

afterEach(() => { cleanup(); navigate.mockReset(); });

const leaf: PaneLeaf = { kind: 'leaf', sessionName: 's1', title: 'bash', attentionText: null, isBusy: false, attentionSource: null };

describe('@spec WEB-9.3 PanePreview', () => {
  it('mounts a preview-role terminal and shows the title', () => {
    render(<PanePreview leaf={leaf} />);
    expect(screen.getByTestId('terminal-pane').getAttribute('data-role')).toBe('preview');
    expect(screen.getByText('bash')).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web-client && npx vitest run src/panes/paneSizing.test.ts src/panes/PanePreview.test.tsx`
Expected: FAIL — modules not found.

- [ ] **Step 3: Write minimal implementations**

```ts
// web-client/src/panes/paneSizing.ts
export function previewFontSize(opts: { tileWidth: number; targetCols: number; cellWidthRatio?: number }): number {
  const { tileWidth, targetCols, cellWidthRatio = 0.6 } = opts;
  if (!Number.isFinite(tileWidth) || tileWidth <= 0 || targetCols <= 0) return 6;
  const raw = tileWidth / (targetCols * cellWidthRatio);
  return Math.min(14, Math.max(6, raw));
}
```

```tsx
// web-client/src/panes/PanePreview.tsx
import { useNavigate } from '@tanstack/react-router';
import { TerminalPane } from '../components/TerminalPane';
import { displayTitle, type PaneLeaf } from '../paneTypes';

export interface PanePreviewProps { leaf: PaneLeaf }

export function PanePreview({ leaf }: PanePreviewProps) {
  const navigate = useNavigate();
  return (
    <button
      type="button"
      className="pane-preview"
      onClick={() => void navigate({ to: '/session/$name', params: { name: leaf.sessionName } })}
    >
      <div className="pane-preview-terminal">
        <TerminalPane sessionName={leaf.sessionName} role="preview" fit="container" autoFocus={false} />
      </div>
      <div className="pane-preview-title">{displayTitle(leaf)}</div>
    </button>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web-client && npx vitest run src/panes/paneSizing.test.ts src/panes/PanePreview.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/panes/paneSizing.ts web-client/src/panes/paneSizing.test.ts web-client/src/panes/PanePreview.tsx web-client/src/panes/PanePreview.test.tsx
git commit -m "feat(web): live PanePreview tile + previewFontSize helper (WEB-9.3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `PaneOverview` (compact worktree detail)

Compose `SplitLayout` + `PanePreview` into the GrafttyMobile-style overview, and short-circuit single-pane worktrees straight to fullscreen.

**Files:**
- Create: `web-client/src/panes/PaneOverview.tsx`
- Test: `web-client/src/panes/PaneOverview.test.tsx`

**Interfaces:**
- Consumes: `SplitLayout`, `PanePreview`, `paneLeaves`, `leafCount`, `PaneLayoutNode` (via `../paneTypes` + `./splitGeometry`), `useNavigate`.
- Produces:
  - `interface PaneOverviewProps { layout: PaneLayoutNode | null }`
  - `function PaneOverview({ layout }: PaneOverviewProps): JSX.Element | null` — if `layout` is `null` → render an empty-state (`<div className="pane-overview-empty">no panes running</div>`); if the layout is a single leaf → `useEffect` navigates to that leaf's fullscreen session (mobile parity IOS-4.17) and renders `null` meanwhile; otherwise render `<SplitLayout node={layout} renderLeaf={(leaf) => <PanePreview leaf={leaf} />} />`.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/panes/PaneOverview.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';
import type { PaneLayoutNode } from '../paneTypes';

const navigate = vi.fn();
vi.mock('@tanstack/react-router', () => ({ useNavigate: () => navigate }));
vi.mock('../components/TerminalPane', () => ({
  TerminalPane: (p: { sessionName: string }) => <div data-testid="tp" data-session={p.sessionName} />,
}));

import { PaneOverview } from './PaneOverview';

afterEach(() => { cleanup(); navigate.mockReset(); });

const leaf = (s: string): PaneLayoutNode => ({ kind: 'leaf', sessionName: s, title: s, attentionText: null, isBusy: false, attentionSource: null });

describe('@spec WEB-9.4 PaneOverview', () => {
  it('renders a preview per leaf for a multi-pane worktree', () => {
    const tree: PaneLayoutNode = { kind: 'split', direction: 'horizontal', ratio: 0.5, left: leaf('a'), right: leaf('b') };
    render(<PaneOverview layout={tree} />);
    expect(screen.getAllByTestId('pane-slot')).toHaveLength(2);
    expect(navigate).not.toHaveBeenCalled();
  });

  it('navigates straight to fullscreen for a single-pane worktree', () => {
    render(<PaneOverview layout={leaf('solo')} />);
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/session/$name', params: { name: 'solo' } }));
  });

  it('shows an empty state when no panes run', () => {
    render(<PaneOverview layout={null} />);
    expect(screen.getByText(/no panes running/i)).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/panes/PaneOverview.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```tsx
// web-client/src/panes/PaneOverview.tsx
import { useEffect } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { SplitLayout } from './SplitLayout';
import { PanePreview } from './PanePreview';
import type { PaneLayoutNode } from '../paneTypes';

export interface PaneOverviewProps { layout: PaneLayoutNode | null }

export function PaneOverview({ layout }: PaneOverviewProps) {
  const navigate = useNavigate();
  const soloSession = layout && layout.kind === 'leaf' ? layout.sessionName : null;

  useEffect(() => {
    if (soloSession) {
      void navigate({ to: '/session/$name', params: { name: soloSession }, replace: true });
    }
  }, [soloSession, navigate]);

  if (!layout) return <div className="pane-overview-empty">no panes running</div>;
  if (soloSession) return null;
  return (
    <div className="pane-overview">
      <SplitLayout node={layout} renderLeaf={(leaf) => <PanePreview leaf={leaf} />} />
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/panes/PaneOverview.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/panes/PaneOverview.tsx web-client/src/panes/PaneOverview.test.tsx
git commit -m "feat(web): PaneOverview compact detail; single-pane skips to fullscreen (WEB-9.4)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `Sidebar` (grouped worktree list, Mac parity)

The desktop worktree selector: repo sections, one row per worktree, grouped `↳` pane child rows when running.

**Files:**
- Create: `web-client/src/layout/Sidebar.tsx`
- Test: `web-client/src/layout/Sidebar.test.tsx`

**Interfaces:**
- Consumes: `RepoGroup` from `../hooks/useWorktreePanes`; `WorktreePanes`, `paneLeaves`, `displayTitle` from `../paneTypes`.
- Produces:
  - `interface SidebarProps { groups: RepoGroup[]; selectedPath: string | null; focusedSessionName: string | null; onSelectWorktree: (path: string) => void; onSelectPane: (worktreePath: string, sessionName: string) => void }`
  - `function Sidebar(props: SidebarProps): JSX.Element` — renders a `<nav className="sidebar">` with one `<section>` per group (`<h2>` = `repoDisplayName`), each worktree a `<button className="wt-row" data-active=…>` (name = `displayName`, dimmed `displayBranch`, PR badge `#<number>` when `prBadge`, divergence `↑ahead ↓behind` when `stats` non-zero, attention capsule when `attentionText`), followed — when `state === 'running'` and the worktree is selected — by a `↳` pane row per leaf (`displayTitle`, `data-busy` from `isBusy`, `data-focused` when `focusedSessionName === leaf.sessionName`). Clicking a worktree row calls `onSelectWorktree(path)`; clicking a pane row calls `onSelectPane(path, sessionName)`.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/layout/Sidebar.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen, fireEvent } from '@testing-library/react';
import { Sidebar } from './Sidebar';
import type { RepoGroup } from '../hooks/useWorktreePanes';
import type { WorktreePanes } from '../paneTypes';

afterEach(cleanup);

const wt: WorktreePanes = {
  path: '/wt/a', displayName: 'feature-x', repoDisplayName: 'graftty', displayBranch: 'feature-x',
  state: 'running', isMainCheckout: false, prBadge: null, stats: { ahead: 2, behind: 1, hasUncommittedChanges: false, baseRef: 'main' },
  attentionText: null,
  layout: { kind: 'split', direction: 'horizontal', ratio: 0.5,
    left: { kind: 'leaf', sessionName: 's1', title: 'bash', attentionText: null, isBusy: false, attentionSource: null },
    right: { kind: 'leaf', sessionName: 's2', title: 'claude', attentionText: null, isBusy: true, attentionSource: null } },
};
const groups: RepoGroup[] = [{ repoDisplayName: 'graftty', worktrees: [wt] }];

describe('@spec WEB-9.6 Sidebar', () => {
  it('groups worktrees under a repo heading and shows divergence', () => {
    render(<Sidebar groups={groups} selectedPath={null} focusedSessionName={null} onSelectWorktree={() => {}} onSelectPane={() => {}} />);
    expect(screen.getByRole('heading', { name: 'graftty' })).toBeTruthy();
    expect(screen.getByText('feature-x')).toBeTruthy();
    expect(screen.getByText(/↑2/)).toBeTruthy();
    expect(screen.getByText(/↓1/)).toBeTruthy();
  });

  it('shows grouped pane rows only for the selected running worktree', () => {
    const { rerender } = render(<Sidebar groups={groups} selectedPath={null} focusedSessionName={null} onSelectWorktree={() => {}} onSelectPane={() => {}} />);
    expect(screen.queryByText('claude')).toBeNull();
    rerender(<Sidebar groups={groups} selectedPath="/wt/a" focusedSessionName={null} onSelectWorktree={() => {}} onSelectPane={() => {}} />);
    expect(screen.getByText('bash')).toBeTruthy();
    expect(screen.getByText('claude')).toBeTruthy();
  });

  it('reports worktree and pane selection', () => {
    const onWt = vi.fn(); const onPane = vi.fn();
    render(<Sidebar groups={groups} selectedPath="/wt/a" focusedSessionName={null} onSelectWorktree={onWt} onSelectPane={onPane} />);
    fireEvent.click(screen.getByText('feature-x'));
    expect(onWt).toHaveBeenCalledWith('/wt/a');
    fireEvent.click(screen.getByText('claude'));
    expect(onPane).toHaveBeenCalledWith('/wt/a', 's2');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/layout/Sidebar.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```tsx
// web-client/src/layout/Sidebar.tsx
import { paneLeaves, displayTitle, type WorktreePanes } from '../paneTypes';
import type { RepoGroup } from '../hooks/useWorktreePanes';

export interface SidebarProps {
  groups: RepoGroup[];
  selectedPath: string | null;
  focusedSessionName: string | null;
  onSelectWorktree: (path: string) => void;
  onSelectPane: (worktreePath: string, sessionName: string) => void;
}

function divergence(wt: WorktreePanes): string | null {
  if (!wt.stats) return null;
  const { ahead, behind } = wt.stats;
  if (ahead === 0 && behind === 0) return null;
  return `↑${ahead} ↓${behind}`;
}

export function Sidebar({ groups, selectedPath, focusedSessionName, onSelectWorktree, onSelectPane }: SidebarProps) {
  return (
    <nav className="sidebar">
      {groups.map((group) => (
        <section key={group.repoDisplayName} className="sidebar-repo">
          <h2>{group.repoDisplayName}</h2>
          {group.worktrees.map((wt) => {
            const active = wt.path === selectedPath;
            const div = divergence(wt);
            return (
              <div key={wt.path} className="wt-block" data-active={active}>
                <button type="button" className="wt-row" data-active={active} onClick={() => onSelectWorktree(wt.path)}>
                  <span className="wt-name" data-main={wt.isMainCheckout}>{wt.displayName}</span>
                  {wt.displayBranch && wt.displayBranch !== wt.displayName
                    ? <span className="wt-branch">{wt.displayBranch}</span> : null}
                  {wt.prBadge ? <span className="wt-pr" data-checks={wt.prBadge.checks}>#{wt.prBadge.number}</span> : null}
                  {div ? <span className="wt-divergence">{div}</span> : null}
                  {wt.attentionText ? <span className="wt-attention">{wt.attentionText}</span> : null}
                </button>
                {active && wt.state === 'running'
                  ? paneLeaves(wt.layout).map((leaf) => (
                      <button
                        key={leaf.sessionName}
                        type="button"
                        className="pane-row"
                        data-busy={leaf.isBusy}
                        data-focused={focusedSessionName === leaf.sessionName}
                        onClick={() => onSelectPane(wt.path, leaf.sessionName)}
                      >
                        <span className="pane-glyph">↳</span>
                        <span className="pane-title">{displayTitle(leaf)}</span>
                        {leaf.attentionText ? <span className="pane-attention">{leaf.attentionText}</span> : null}
                      </button>
                    ))
                  : null}
              </div>
            );
          })}
        </section>
      ))}
    </nav>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/layout/Sidebar.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/layout/Sidebar.tsx web-client/src/layout/Sidebar.test.tsx
git commit -m "feat(web): grouped worktree Sidebar with pane child rows (WEB-9.6)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `DesktopShell` (sidebar + interactive split content + focus)

The desktop experience: persistent sidebar beside the selected worktree's interactive split layout, with local focus.

**Files:**
- Create: `web-client/src/layout/DesktopShell.tsx`
- Test: `web-client/src/layout/DesktopShell.test.tsx`

**Interfaces:**
- Consumes: `useWorktreePanes`, `Sidebar`, `SplitLayout`, `TerminalPane`, `paneLeaves`.
- Produces:
  - `function DesktopShell(): JSX.Element` — calls `useWorktreePanes()`; holds `selectedPath` and `focusedSessionName` state; derives the selected `WorktreePanes` (default: first worktree in the first group; a `?path=` search param, if present, wins). Renders `<div className="desktop-shell"><Sidebar …/><main className="desktop-content">…</main></div>`. The content: if the selected worktree has a `layout`, render `<SplitLayout node={layout} renderLeaf={(leaf) => <InteractivePaneTile leaf focused={focusedSessionName===leaf.sessionName} onFocus={…} />} />` where each tile wraps `<TerminalPane sessionName role="interactive" fit="container" autoFocus={focused} />` in a `<div className="pane-tile" data-focused=… onMouseDown={() => setFocusedSessionName(leaf.sessionName)}>`; else render `<div className="desktop-empty">select a worktree</div>`. When `selectedPath` changes, reset `focusedSessionName` to the first leaf of the newly selected worktree (so keyboard has a home).

**Note:** Keep `InteractivePaneTile` as a small local component in the same file (it is desktop-only glue, not reused). Clicking a sidebar pane row (`onSelectPane`) sets both `selectedPath` and `focusedSessionName`.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/layout/DesktopShell.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen, fireEvent } from '@testing-library/react';

vi.mock('@tanstack/react-router', () => ({ useNavigate: () => vi.fn(), useSearch: () => ({}) }));
vi.mock('../components/TerminalPane', () => ({
  TerminalPane: (p: { sessionName: string; autoFocus?: boolean }) =>
    <div data-testid="tp" data-session={p.sessionName} data-autofocus={String(p.autoFocus)} />,
}));
const state = {
  kind: 'ready' as const,
  worktrees: [] as unknown[],
  groups: [{ repoDisplayName: 'graftty', worktrees: [{
    path: '/wt/a', displayName: 'a', repoDisplayName: 'graftty', displayBranch: 'a', state: 'running',
    isMainCheckout: false, prBadge: null, stats: null, attentionText: null,
    layout: { kind: 'split', direction: 'horizontal', ratio: 0.5,
      left: { kind: 'leaf', sessionName: 's1', title: 'bash', attentionText: null, isBusy: false, attentionSource: null },
      right: { kind: 'leaf', sessionName: 's2', title: 'claude', attentionText: null, isBusy: false, attentionSource: null } },
  }] }],
};
vi.mock('../hooks/useWorktreePanes', async () => {
  const actual = await vi.importActual<typeof import('../hooks/useWorktreePanes')>('../hooks/useWorktreePanes');
  return { ...actual, useWorktreePanes: () => state };
});

import { DesktopShell } from './DesktopShell';

afterEach(cleanup);

describe('@spec WEB-9.7 DesktopShell', () => {
  it('auto-selects the first worktree and renders its interactive panes', () => {
    render(<DesktopShell />);
    const tps = screen.getAllByTestId('tp');
    expect(tps.map((t) => t.getAttribute('data-session')).sort()).toEqual(['s1', 's2']);
  });

  it('focuses the clicked pane (autoFocus flips to that tile)', () => {
    render(<DesktopShell />);
    fireEvent.mouseDown(screen.getAllByTestId('pane-slot')[1]);
    const s2 = screen.getAllByTestId('tp').find((t) => t.getAttribute('data-session') === 's2');
    expect(s2?.getAttribute('data-autofocus')).toBe('true');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/layout/DesktopShell.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```tsx
// web-client/src/layout/DesktopShell.tsx
import { useEffect, useMemo, useState } from 'react';
import { Sidebar } from './Sidebar';
import { SplitLayout } from '../panes/SplitLayout';
import { TerminalPane } from '../components/TerminalPane';
import { paneLeaves, type PaneLeaf, type WorktreePanes } from '../paneTypes';
import { useWorktreePanes } from '../hooks/useWorktreePanes';

function firstWorktree(groups: { worktrees: WorktreePanes[] }[]): WorktreePanes | null {
  for (const g of groups) if (g.worktrees.length) return g.worktrees[0];
  return null;
}

function InteractivePaneTile({ leaf, focused, onFocus }: { leaf: PaneLeaf; focused: boolean; onFocus: () => void }) {
  return (
    <div className="pane-tile" data-focused={focused} onMouseDown={onFocus}
         style={{ width: '100%', height: '100%' }}>
      <TerminalPane sessionName={leaf.sessionName} role="interactive" fit="container" autoFocus={focused} />
    </div>
  );
}

export function DesktopShell() {
  const state = useWorktreePanes();
  const groups = state.kind === 'ready' ? state.groups : [];
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [focusedSessionName, setFocusedSessionName] = useState<string | null>(null);

  const selected = useMemo<WorktreePanes | null>(() => {
    const all = groups.flatMap((g) => g.worktrees);
    return all.find((w) => w.path === selectedPath) ?? firstWorktree(groups);
  }, [groups, selectedPath]);

  useEffect(() => {
    if (!selected) return;
    const leaves = paneLeaves(selected.layout);
    if (!leaves.some((l) => l.sessionName === focusedSessionName)) {
      setFocusedSessionName(leaves[0]?.sessionName ?? null);
    }
  }, [selected, focusedSessionName]);

  return (
    <div className="desktop-shell">
      <Sidebar
        groups={groups}
        selectedPath={selected?.path ?? null}
        focusedSessionName={focusedSessionName}
        onSelectWorktree={setSelectedPath}
        onSelectPane={(path, session) => { setSelectedPath(path); setFocusedSessionName(session); }}
      />
      <main className="desktop-content">
        {selected?.layout
          ? <SplitLayout
              node={selected.layout}
              renderLeaf={(leaf) => (
                <InteractivePaneTile
                  leaf={leaf}
                  focused={focusedSessionName === leaf.sessionName}
                  onFocus={() => setFocusedSessionName(leaf.sessionName)}
                />
              )}
            />
          : <div className="desktop-empty">select a worktree</div>}
      </main>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/layout/DesktopShell.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/layout/DesktopShell.tsx web-client/src/layout/DesktopShell.test.tsx
git commit -m "feat(web): DesktopShell sidebar + interactive split content + local focus (WEB-9.7)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Compact pages — `WorktreeListPage` + `worktree.$path` route

The compact full-page grouped list and the compact worktree-detail route that renders `PaneOverview`.

**Files:**
- Create: `web-client/src/layout/WorktreeListPage.tsx`
- Create: `web-client/src/layout/WorktreeListPage.test.tsx`
- Create: `web-client/src/routes/worktree.$path.tsx`

**Interfaces:**
- Consumes: `useWorktreePanes`, `paneLeaves`, `displayTitle`, `useNavigate`, `useParams`, `PaneOverview`.
- Produces:
  - `function WorktreeListPage(): JSX.Element` — `useWorktreePanes()`; renders the same grouped structure as `Sidebar` but as a full page. Each worktree row navigates: single-pane → `/session/$name` (its only leaf); multi-pane → `/worktree/$path` (encode the path). Includes the `+ Add worktree` link (`to="/new"`) preserved from today's index.
  - `function WorktreeDetailPage(): JSX.Element` — reads `useParams({ from: '/worktree/$path' })`, decodes the path, finds the worktree in `useWorktreePanes()`, and renders `<PaneOverview layout={worktree?.layout ?? null} />`.

**Note:** TanStack path param `$path` will contain a URL-encoded worktree path; encode with `encodeURIComponent` at the call site and decode with `decodeURIComponent` when reading the param.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/layout/WorktreeListPage.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen, fireEvent } from '@testing-library/react';

const navigate = vi.fn();
vi.mock('@tanstack/react-router', () => ({ useNavigate: () => navigate, Link: (p: { children: React.ReactNode }) => <a>{p.children}</a> }));
const wt = (path: string, single: boolean) => ({
  path, displayName: path, repoDisplayName: 'graftty', displayBranch: 'b', state: 'running',
  isMainCheckout: false, prBadge: null, stats: null, attentionText: null,
  layout: single
    ? { kind: 'leaf', sessionName: 'solo', title: 't', attentionText: null, isBusy: false, attentionSource: null }
    : { kind: 'split', direction: 'horizontal', ratio: 0.5,
        left: { kind: 'leaf', sessionName: 's1', title: 't', attentionText: null, isBusy: false, attentionSource: null },
        right: { kind: 'leaf', sessionName: 's2', title: 't', attentionText: null, isBusy: false, attentionSource: null } },
});
vi.mock('../hooks/useWorktreePanes', async () => {
  const actual = await vi.importActual<typeof import('../hooks/useWorktreePanes')>('../hooks/useWorktreePanes');
  return { ...actual, useWorktreePanes: () => ({ kind: 'ready', worktrees: [], groups: [{ repoDisplayName: 'graftty', worktrees: [wt('/wt/single', true), wt('/wt/multi', false)] }] }) };
});
import { WorktreeListPage } from './WorktreeListPage';

afterEach(() => { cleanup(); navigate.mockReset(); });

describe('@spec WEB-9.8 WorktreeListPage', () => {
  it('routes a single-pane worktree straight to its session', () => {
    render(<WorktreeListPage />);
    fireEvent.click(screen.getByText('/wt/single'));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/session/$name', params: { name: 'solo' } }));
  });
  it('routes a multi-pane worktree to its overview', () => {
    render(<WorktreeListPage />);
    fireEvent.click(screen.getByText('/wt/multi'));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/worktree/$path' }));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/layout/WorktreeListPage.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementations**

```tsx
// web-client/src/layout/WorktreeListPage.tsx
import { Link, useNavigate } from '@tanstack/react-router';
import { useWorktreePanes } from '../hooks/useWorktreePanes';
import { paneLeaves, type WorktreePanes } from '../paneTypes';

export function WorktreeListPage() {
  const state = useWorktreePanes();
  const navigate = useNavigate();
  if (state.kind === 'loading') return <div className="picker-status">loading…</div>;
  if (state.kind === 'error') return <div className="picker-status picker-error">error: {state.message}</div>;

  const open = (wt: WorktreePanes) => {
    const leaves = paneLeaves(wt.layout);
    if (leaves.length === 1) {
      void navigate({ to: '/session/$name', params: { name: leaves[0].sessionName } });
    } else {
      void navigate({ to: '/worktree/$path', params: { path: encodeURIComponent(wt.path) } });
    }
  };

  return (
    <div className="picker">
      <div className="picker-header">
        <h1>Graftty worktrees</h1>
        <Link to="/new" className="picker-add-worktree">+ Add worktree</Link>
      </div>
      {state.groups.map((group) => (
        <section key={group.repoDisplayName} className="picker-repo">
          <h2>{group.repoDisplayName}</h2>
          <ul>
            {group.worktrees.map((wt) => (
              <li key={wt.path}>
                <button type="button" className="picker-session" onClick={() => open(wt)}>
                  <span className="picker-label">{wt.displayName}</span>
                  <span className="picker-path">{wt.displayBranch}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}
```

```tsx
// web-client/src/routes/worktree.$path.tsx
import { useParams } from '@tanstack/react-router';
import { useWorktreePanes } from '../hooks/useWorktreePanes';
import { PaneOverview } from '../panes/PaneOverview';

export function WorktreeDetailPage() {
  const { path } = useParams({ from: '/worktree/$path' });
  const worktreePath = decodeURIComponent(path);
  const state = useWorktreePanes();
  const worktree = state.kind === 'ready'
    ? state.worktrees.find((w) => w.path === worktreePath) ?? null
    : null;
  return <PaneOverview layout={worktree?.layout ?? null} />;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web-client && npx vitest run src/layout/WorktreeListPage.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/layout/WorktreeListPage.tsx web-client/src/layout/WorktreeListPage.test.tsx web-client/src/routes/worktree.\$path.tsx
git commit -m "feat(web): compact worktree list + overview route (WEB-9.8)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Wire the width branch — `AppRoot`, router, styles

Connect everything: the root branches on width, the router gains the `/worktree/$path` route, `index` becomes the compact list, and the CSS supports the sidebar + split chrome.

**Files:**
- Create: `web-client/src/layout/AppRoot.tsx`
- Modify: `web-client/src/routes/__root.tsx`
- Modify: `web-client/src/routes/index.tsx`
- Modify: `web-client/src/router.tsx`
- Modify: `web-client/src/styles.css`
- Test: `web-client/src/layout/AppRoot.test.tsx`

**Interfaces:**
- Consumes: `useIsDesktop`, `DesktopShell`, `Outlet` from `@tanstack/react-router`.
- Produces:
  - `function AppRoot({ children }: { children: React.ReactNode }): JSX.Element` — if `useIsDesktop()` → render `<DesktopShell />`; else render `children` (the route Outlet). Exported so `__root.tsx` wraps `<Outlet/>` with it.

**Behavior details:**
- `__root.tsx`: `<div id="app"><AppRoot><Outlet /></AppRoot></div>`.
- `index.tsx`: replace the `/sessions` `IndexPage` body with `WorktreeListPage` (keep the legacy `?session=` redirect effect at the top). At desktop width the `AppRoot` branch renders `DesktopShell` instead of the Outlet, so `index`'s content only shows at compact width.
- `router.tsx`: add `worktreeRoute` for `path: '/worktree/$path'` → `WorktreeDetailPage`; register it in `addChildren`.
- `styles.css`: add `.desktop-shell` (flex row), `.sidebar` (fixed/ës min-width ~260px, themed surface, scroll), `.desktop-content` (flex:1), `.wt-row`/`.pane-row`/`.wt-block[data-active=true]` highlight, `.split-container`/`.split-divider`/`.pane-slot`/`.pane-tile[data-focused=true]` active border, `.pane-overview`/`.pane-preview`/`.pane-preview-title`, and the renamed `.term-host`/`.term-status`/`.term-take-control` (moved from `#term`/`#status`/`#take-control`). Keep status-cue convention: `data-busy=true` → dim/italic, not saturated; active highlights subtle.

- [ ] **Step 1: Write the failing test**

```tsx
// web-client/src/layout/AppRoot.test.tsx
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';

vi.mock('./DesktopShell', () => ({ DesktopShell: () => <div data-testid="desktop-shell" /> }));
const isDesktop = { value: false };
vi.mock('../hooks/useIsDesktop', () => ({ useIsDesktop: () => isDesktop.value, DESKTOP_MIN_WIDTH: 900 }));

import { AppRoot } from './AppRoot';

afterEach(cleanup);

describe('@spec WEB-9.1 AppRoot width branch', () => {
  it('renders the compact Outlet below the breakpoint', () => {
    isDesktop.value = false;
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('compact-child')).toBeTruthy();
    expect(screen.queryByTestId('desktop-shell')).toBeNull();
  });
  it('renders the DesktopShell at or above the breakpoint', () => {
    isDesktop.value = true;
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('desktop-shell')).toBeTruthy();
    expect(screen.queryByTestId('compact-child')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web-client && npx vitest run src/layout/AppRoot.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write / apply implementations**

```tsx
// web-client/src/layout/AppRoot.tsx
import type { ReactNode } from 'react';
import { useIsDesktop } from '../hooks/useIsDesktop';
import { DesktopShell } from './DesktopShell';

export function AppRoot({ children }: { children: ReactNode }) {
  return useIsDesktop() ? <DesktopShell /> : <>{children}</>;
}
```

```tsx
// web-client/src/routes/__root.tsx
import { Outlet } from '@tanstack/react-router';
import { AppRoot } from '../layout/AppRoot';

export function RootLayout() {
  return (
    <div id="app">
      <AppRoot>
        <Outlet />
      </AppRoot>
    </div>
  );
}
```

Then:
- Rewrite `routes/index.tsx` so `IndexPage` keeps the `?session=` redirect `useEffect` and returns `<WorktreeListPage />` (import from `../layout/WorktreeListPage`). Remove the `/sessions` fetch/`SessionInfo` code.
- In `router.tsx`, add:
  ```ts
  import { WorktreeDetailPage } from './routes/worktree.$path';
  const worktreeRoute = createRoute({ getParentRoute: () => rootRoute, path: '/worktree/$path', component: WorktreeDetailPage });
  // add worktreeRoute to addChildren([...])
  ```
- Apply the `styles.css` additions/renames described above.

- [ ] **Step 4: Run the full web test suite + build**

Run: `cd web-client && npm test && npm run build`
Expected: All Vitest suites PASS; `vite build` succeeds and emits a single `app.js`/`app.css` into `../dist-tmp`.

- [ ] **Step 5: Commit**

```bash
git add web-client/src/layout/AppRoot.tsx web-client/src/layout/AppRoot.test.tsx web-client/src/routes/__root.tsx web-client/src/routes/index.tsx web-client/src/router.tsx web-client/src/styles.css
git commit -m "feat(web): width-branched AppRoot wiring sidebar + worktree routes (WEB-9.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Record `WEB-9.x` specs + regenerate `SPECS.md`

Capture the new requirements in the `@spec` system and refresh generated docs.

**Files:**
- Modify: `Tests/GrafttyTests/Specs/WebTodo.swift` (add any `WEB-9.x` not already carried by a live vitest test name)
- Modify: `SPECS.md` (regenerated)

**Interfaces:** none (documentation task).

**Requirements to record (EARS, no literal quotes in titles):**
- `WEB-9.1` — While the web viewport is at desktop width, the application shall present a persistent worktree sidebar alongside the pane content.
- `WEB-9.2` — When rendering a worktree pane tree, the application shall lay panes out in nested proportional splits mirroring the host split ratios.
- `WEB-9.3` — While showing a pane overview, the application shall render each pane as a live read-only terminal preview.
- `WEB-9.4` — When a worktree has exactly one pane, the application shall open that pane fullscreen instead of showing an overview.
- `WEB-9.5` — While a pane is rendered as a preview, the application shall connect in the preview display role and never claim display ownership.
- `WEB-9.6` — When listing worktrees, the application shall group panes under their worktree rather than listing each pane separately.
- `WEB-9.7` — While at desktop width, the application shall render the selected worktree panes as fully interactive terminals with click-to-focus keyboard routing.
- `WEB-9.8` — While at compact width, the application shall navigate worktree list to overview to fullscreen as a push flow.

- [ ] **Step 1: Add the inventory entries**

For each `WEB-9.x` above that is **not** already carried verbatim by a live vitest `@spec` test title (Tasks 5–12 carry 9.1–9.8 in test names), leave a `.disabled` entry out — since all are implemented, they belong in a real test, not the Todo inventory. Confirm with:

Run: `grep -rn "@spec WEB-9" web-client Tests`
Expected: each of `WEB-9.1`…`WEB-9.8` appears in exactly one live test title (vitest), none duplicated in `WebTodo.swift`.

If any `WEB-9.x` lacks a live test, add a `.disabled("not yet implemented")` `@Test` for it in `WebTodo.swift` following the file's existing pattern.

- [ ] **Step 2: Regenerate SPECS.md**

Run: `python3 scripts/generate-specs.py`
Expected: exits 0; `SPECS.md` now contains a `WEB-9.x` block. (The generator scans `@spec` annotations across the repo, including the vitest test titles if the scanner covers `web-client`; if it does not scan TS, add the `WEB-9.x` EARS lines as `.disabled` inventory entries in `WebTodo.swift` so they appear in `SPECS.md`, then re-run.)

- [ ] **Step 3: Verify the check passes**

Run: `python3 scripts/generate-specs.py --check`
Expected: exits 0 (SPECS.md not stale, no duplicate/active+disabled conflicts).

- [ ] **Step 4: Commit**

```bash
git add SPECS.md Tests/GrafttyTests/Specs/WebTodo.swift
git commit -m "docs(specs): record WEB-9.x web pane selector requirements

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-06-30-web-pane-selector-design.md`):
- Worktree-grouped selector (Mac parity) → Task 9 (Sidebar) + Task 11 (compact list). ✓
- GrafttyMobile-style live pane overview → Tasks 6, 7, 8. ✓
- Single-pane skips overview → Task 8. ✓
- Desktop sidebar + interactive split (Mac parity) → Tasks 9, 10, 12. ✓
- Read-only dividers → Task 6 (fixed divider, no drag handlers). ✓
- Preview never claims ownership → Task 5 (`sendOwnerResize`/input no-ops) + Task 7 wiring + WEB-9.5 test. ✓
- Width branch @900px → Tasks 3, 12. ✓
- Reuse `TerminalPane` / ownership → Task 5 (multi-instance safe, role/fit). ✓
- Data via `/worktrees/panes` polling → Task 4. ✓
- Ghostty theming of sidebar → Task 12 styles (uses existing themed surface; explicit `/ghostty-config`-driven variables can layer on later without new tasks). ✓
- Testing (vitest units incl. ownership guard) + WEB-9.x specs → each task + Task 13. ✓
- Zero backend change → held across all tasks (Global Constraints). ✓

**2. Placeholder scan:** no TBD/TODO; each code step carries full code; each test step has real assertions. ✓

**3. Type consistency:** `PaneLayoutNode`/`PaneLeaf`/`WorktreePanes` (Task 1) are consumed unchanged in Tasks 2, 6, 7, 8, 9, 10, 11. `RepoGroup` (Task 4) consumed in Tasks 9, 10, 11. `TerminalPaneProps` role/fit/autoFocus (Task 5) consumed in Tasks 7, 10. `flexBasisForRatio`/`flexDirectionFor` (Task 2) consumed in Task 6. Names match across tasks. ✓

**Note for the executor:** After all tasks, run `/code-review max --fix` over the branch diff (per project convention and the user's request) before opening a PR.

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

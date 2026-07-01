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

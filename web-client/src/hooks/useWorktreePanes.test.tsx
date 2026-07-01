import { describe, it, expect, vi, afterEach } from 'vitest';
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
  afterEach(() => vi.unstubAllGlobals());

  it('fetches and exposes grouped worktrees', async () => {
    const fetchMock = vi.fn(async () => ({
      ok: true,
      json: async () => [wt('/a', 'r1')],
    }));
    vi.stubGlobal('fetch', fetchMock as unknown as typeof fetch);
    const { result } = renderHook(() => useWorktreePanes(10_000));
    await waitFor(() => expect(result.current.kind).toBe('ready'));
    if (result.current.kind === 'ready') {
      expect(result.current.groups[0].repoDisplayName).toBe('r1');
    }
    expect(fetchMock).toHaveBeenCalledWith('/worktrees/panes', { credentials: 'same-origin' });
  });

  it('keeps last-good state when a later poll fails', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => [wt('/a', 'r1')] })
      .mockRejectedValue(new Error('network error'));
    vi.stubGlobal('fetch', fetchMock as unknown as typeof fetch);
    const { result } = renderHook(() => useWorktreePanes(10));
    // First poll succeeds — state becomes ready
    await waitFor(() => expect(result.current.kind).toBe('ready'));
    // Wait for at least one failing poll to have fired
    await waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(2));
    // State must remain ready; last-good data is preserved on error
    expect(result.current.kind).toBe('ready');
  });
});

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

// @spec WEB-9.8: While at compact width, the application shall navigate worktree list to overview to fullscreen as a push flow.
describe('WorktreeListPage', () => {
  it('routes a single-pane worktree straight to its session', () => {
    render(<WorktreeListPage />);
    fireEvent.click(screen.getByText('/wt/single'));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/session/$name', params: { name: 'solo' } }));
  });
  it('routes a multi-pane worktree to its overview', () => {
    render(<WorktreeListPage />);
    fireEvent.click(screen.getByText('/wt/multi'));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/worktree/$path', params: { path: encodeURIComponent('/wt/multi') } }));
  });
});

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

// @spec WEB-9.6: When listing worktrees, the application shall group panes under their worktree rather than listing each pane separately.
describe('Sidebar', () => {
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

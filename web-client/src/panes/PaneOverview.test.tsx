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

// @spec WEB-9.4: When a worktree has exactly one pane, the application shall open that pane fullscreen instead of showing an overview.
describe('PaneOverview', () => {
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

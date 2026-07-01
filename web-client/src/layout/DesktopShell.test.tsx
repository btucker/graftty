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

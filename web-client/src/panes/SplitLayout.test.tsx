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

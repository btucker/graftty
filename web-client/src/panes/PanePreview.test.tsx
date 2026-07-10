import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen, fireEvent } from '@testing-library/react';
import type { PaneLeaf } from '../paneTypes';

const navigate = vi.fn();
vi.mock('@tanstack/react-router', () => ({ useNavigate: () => navigate }));
// Stub TerminalPane so the preview test doesn't boot ghostty-web/WASM.
vi.mock('../components/TerminalPane', () => ({
  TerminalPane: (props: { sessionName: string; role?: string; fit?: string; autoFocus?: boolean }) =>
    <div data-testid="terminal-pane" data-session={props.sessionName} data-role={props.role} data-fit={props.fit} data-autofocus={String(props.autoFocus)} />,
}));

import { PanePreview } from './PanePreview';

afterEach(() => { cleanup(); navigate.mockReset(); });

const leaf: PaneLeaf = { kind: 'leaf', sessionName: 's1', title: 'bash', attentionText: null, isBusy: false, attentionSource: null };

// @spec WEB-9.3: While showing a pane overview, the application shall render each pane as a live read-only terminal preview.
describe('PanePreview', () => {
  it('mounts a preview-role terminal and shows the title', () => {
    render(<PanePreview leaf={leaf} />);
    const terminal = screen.getByTestId('terminal-pane');
    expect(terminal.getAttribute('data-role')).toBe('preview');
    expect(terminal.getAttribute('data-fit')).toBe('container');
    expect(terminal.getAttribute('data-autofocus')).toBe('false');
    expect(screen.getByText('bash')).toBeTruthy();
  });

  it('navigates to the session route on click', () => {
    render(<PanePreview leaf={leaf} />);
    fireEvent.click(screen.getByRole('button'));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: '/session/$name', params: { name: 's1' } }));
  });
});

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

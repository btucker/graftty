import { cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, expect, test, vi } from 'vitest';
import { IndexPage } from './index';

const navigateMock = vi.hoisted(() => vi.fn());

vi.mock('@tanstack/react-router', () => ({
  useNavigate: () => navigateMock,
}));

// WorktreeListPage is tested independently; stub it here so IndexPage renders
// without needing its real data hooks.
vi.mock('../layout/WorktreeListPage', () => ({
  WorktreeListPage: () => <div data-testid="worktree-list-page" />,
}));

afterEach(() => {
  cleanup();
  navigateMock.mockReset();
  window.history.pushState({}, '', '/');
});

test('root route redirects legacy session query URLs', async () => {
  window.history.pushState({}, '', '/?session=graftty-legacy');

  render(<IndexPage />);

  await waitFor(() => {
    expect(navigateMock).toHaveBeenCalledWith({
      to: '/session/$name',
      params: { name: 'graftty-legacy' },
      replace: true,
    });
  });
});

test('root route renders WorktreeListPage when no session query param is present', () => {
  const { getByTestId } = render(<IndexPage />);
  expect(getByTestId('worktree-list-page')).toBeTruthy();
});

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, expect, test, vi } from 'vitest';
import { IndexPage } from './index';

const navigateMock = vi.hoisted(() => vi.fn());

vi.mock('@tanstack/react-router', () => ({
  Link: ({
    to,
    params,
    children,
    className,
  }: {
    to: string;
    params?: { name?: string };
    children: ReactNode;
    className?: string;
  }) => {
    const href = params?.name ? to.replace('$name', params.name) : to;
    return <a href={href} className={className}>{children}</a>;
  },
  useNavigate: () => navigateMock,
}));

interface SessionInfo {
  name: string;
  worktreePath: string;
  repoDisplayName: string;
  worktreeDisplayName: string;
}

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

function installFetch(sessions: SessionInfo[]) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string'
      ? input
      : input instanceof URL
        ? input.pathname
        : input.url;
    if (url === '/sessions') return jsonResponse(sessions);
    throw new Error(`unexpected fetch ${url}`);
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  navigateMock.mockReset();
  window.history.pushState({}, '', '/');
});

test('root route redirects legacy session query URLs', async () => {
  window.history.pushState({}, '', '/?session=graftty-legacy');
  installFetch([]);

  render(<IndexPage />);

  await waitFor(() => {
    expect(navigateMock).toHaveBeenCalledWith({
      to: '/session/$name',
      params: { name: 'graftty-legacy' },
      replace: true,
    });
  });
});

test('root route fetches sessions and renders a grouped picker', async () => {
  const fetchMock = installFetch([
    {
      name: 'graftty-alpha',
      worktreePath: '/repos/alpha',
      repoDisplayName: 'alpha',
      worktreeDisplayName: 'main',
    },
    {
      name: 'graftty-feature',
      worktreePath: '/repos/alpha/.worktrees/feature',
      repoDisplayName: 'alpha',
      worktreeDisplayName: 'feature',
    },
    {
      name: 'graftty-beta',
      worktreePath: '/repos/beta',
      repoDisplayName: 'beta',
      worktreeDisplayName: 'root',
    },
  ]);

  render(<IndexPage />);

  expect(await screen.findByRole('heading', { name: 'alpha' })).toBeTruthy();
  expect(screen.getByRole('heading', { name: 'beta' })).toBeTruthy();
  expect(screen.getByRole('link', { name: /main/ }).getAttribute('href')).toBe('/session/graftty-alpha');
  expect(screen.getByRole('link', { name: /feature/ }).getAttribute('href')).toBe('/session/graftty-feature');
  expect(screen.getByRole('link', { name: /root/ }).getAttribute('href')).toBe('/session/graftty-beta');
  expect(screen.getByRole('link', { name: '+ Add worktree' }).getAttribute('href')).toBe('/new');
  expect(fetchMock).toHaveBeenCalledWith('/sessions', { credentials: 'same-origin' });
});

test('root route offers worktree creation when there are no running sessions', async () => {
  installFetch([]);

  render(<IndexPage />);

  expect(await screen.findByText('No running sessions yet.')).toBeTruthy();
  expect(screen.getByRole('link', { name: '+ Add worktree' }).getAttribute('href')).toBe('/new');
});

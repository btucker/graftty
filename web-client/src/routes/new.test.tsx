import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, expect, test, vi } from 'vitest';
import { NewWorktreePage } from './new';

const navigateMock = vi.hoisted(() => vi.fn());

vi.mock('@tanstack/react-router', () => ({
  Link: ({ to, children, className }: { to: string; children: ReactNode; className?: string }) => (
    <a href={to} className={className}>{children}</a>
  ),
  useNavigate: () => navigateMock,
}));

interface RepoInfo {
  path: string;
  displayName: string;
}

interface FetchSetup {
  repos: RepoInfo[];
  post?: (init?: RequestInit) => Promise<Response>;
}

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

function installFetch({ repos, post }: FetchSetup) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string'
      ? input
      : input instanceof URL
        ? input.pathname
        : input.url;
    if (url === '/repos') return jsonResponse(repos);
    if (url === '/worktrees' && post) return post(init);
    throw new Error(`unexpected fetch ${url}`);
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  navigateMock.mockReset();
});

// @spec WEB-7.6: The bundled web client shall expose an "Add worktree" entry point on its root page that routes to `/new`. `/new` shall render a form containing (a) a repository picker populated from `GET /repos` (hidden when only one repo is tracked), (b) a worktree-name field, (c) a branch-name field defaulting to mirror the worktree-name field until the user types a differing branch name. Both name fields shall sanitize input live to the same allowed set as the native sheet (`A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`) and shall trim whitespace plus leading/trailing `-` / `.` at submit time. On successful `POST /worktrees` the client shall navigate to `/session/<sessionName>`; on failure it shall display the server's `error` message inline next to the form.
test('new worktree form mirrors, sanitizes, submits, and navigates', async () => {
  const user = userEvent.setup();
  const postedBodies: unknown[] = [];
  installFetch({
    repos: [
      { path: '/repo/alpha', displayName: 'alpha' },
      { path: '/repo/beta', displayName: 'beta' },
    ],
    post: async (init) => {
      postedBodies.push(JSON.parse(String(init?.body)));
      return jsonResponse({
        sessionName: 'graftty-abcdef12',
        worktreePath: '/repo/beta/.worktrees/my-feature/foo-x',
      });
    },
  });

  render(<NewWorktreePage />);

  const repo = await screen.findByLabelText('Repository') as HTMLSelectElement;
  expect([...repo.options].map((option) => option.textContent)).toEqual(['alpha', 'beta']);
  await user.selectOptions(repo, '/repo/beta');

  const worktreeName = screen.getByLabelText('Worktree name') as HTMLInputElement;
  const branchName = screen.getByLabelText('Branch') as HTMLInputElement;
  await user.type(worktreeName, ' my feature/foo!');
  expect(worktreeName.value).toBe('-my-feature/foo-');
  expect(branchName.value).toBe('-my-feature/foo-');

  await user.clear(branchName);
  await user.type(branchName, 'release candidate');
  expect(branchName.value).toBe('release-candidate');

  await user.type(worktreeName, 'x');
  expect(worktreeName.value).toBe('-my-feature/foo-x');
  expect(branchName.value).toBe('release-candidate');

  await user.click(screen.getByRole('button', { name: 'Create' }));

  await waitFor(() => {
    expect(navigateMock).toHaveBeenCalledWith({
      to: '/session/$name',
      params: { name: 'graftty-abcdef12' },
    });
  });
  expect(postedBodies).toEqual([{
    repoPath: '/repo/beta',
    worktreeName: 'my-feature/foo-x',
    branchName: 'release-candidate',
  }]);
});

test('new worktree form hides repository picker when only one repo exists', async () => {
  installFetch({
    repos: [{ path: '/repo/alpha', displayName: 'alpha' }],
    post: async () => jsonResponse({ sessionName: 'graftty-one', worktreePath: '/repo/alpha/.worktrees/one' }),
  });

  render(<NewWorktreePage />);

  await screen.findByLabelText('Worktree name');
  expect(screen.queryByLabelText('Repository')).toBeNull();
});

test('new worktree form renders server errors inline', async () => {
  const user = userEvent.setup();
  installFetch({
    repos: [{ path: '/repo/alpha', displayName: 'alpha' }],
    post: async () => jsonResponse({ error: 'fatal: branch already exists' }, 409),
  });

  render(<NewWorktreePage />);

  await user.type(await screen.findByLabelText('Worktree name'), 'feature-x');
  await user.click(screen.getByRole('button', { name: 'Create' }));

  expect(await screen.findByText('fatal: branch already exists')).toBeTruthy();
  expect(navigateMock).not.toHaveBeenCalled();
});

// @spec WEB-7.7: When `AppState.repos` is empty (no repositories tracked yet), the `/new` route shall render an empty-state message directing the user to open a repository in the native Graftty app first, with a back-link to `/`. The web client shall not implement repository-adding (the Mac-side file dialog + security-scoped bookmark mint has no web equivalent in Phase 2).
test('new worktree route renders empty state when no repos are tracked', async () => {
  installFetch({ repos: [] });

  render(<NewWorktreePage />);

  expect(await screen.findByText('No repositories tracked. Open one in Graftty first.')).toBeTruthy();
  expect(screen.getByRole('link', { name: /Back to sessions/ }).getAttribute('href')).toBe('/');
  expect(screen.queryByLabelText('Worktree name')).toBeNull();
});

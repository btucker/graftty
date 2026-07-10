import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';

vi.mock('./DesktopShell', () => ({ DesktopShell: () => <div data-testid="desktop-shell" /> }));
const isDesktop = { value: false };
vi.mock('../hooks/useIsDesktop', () => ({ useIsDesktop: () => isDesktop.value, DESKTOP_MIN_WIDTH: 900 }));
const location = { pathname: '/' };
vi.mock('@tanstack/react-router', () => ({ useRouterState: ({ select }: { select: (s: { location: { pathname: string } }) => string }) => select({ location }) }));

import { AppRoot } from './AppRoot';

afterEach(cleanup);

// @spec WEB-9.1: While the web viewport is at desktop width, the application shall present a persistent worktree sidebar alongside the pane content.
describe('AppRoot width branch', () => {
  it('renders the compact Outlet below the breakpoint', () => {
    isDesktop.value = false;
    location.pathname = '/';
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('compact-child')).toBeTruthy();
    expect(screen.queryByTestId('desktop-shell')).toBeNull();
  });
  it('renders the DesktopShell at or above the breakpoint', () => {
    isDesktop.value = true;
    location.pathname = '/';
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('desktop-shell')).toBeTruthy();
    expect(screen.queryByTestId('compact-child')).toBeNull();
  });
  it('renders children at desktop width when pathname is /new', () => {
    isDesktop.value = true;
    location.pathname = '/new';
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('compact-child')).toBeTruthy();
    expect(screen.queryByTestId('desktop-shell')).toBeNull();
  });
});

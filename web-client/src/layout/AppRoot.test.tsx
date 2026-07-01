import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen } from '@testing-library/react';

vi.mock('./DesktopShell', () => ({ DesktopShell: () => <div data-testid="desktop-shell" /> }));
const isDesktop = { value: false };
vi.mock('../hooks/useIsDesktop', () => ({ useIsDesktop: () => isDesktop.value, DESKTOP_MIN_WIDTH: 900 }));

import { AppRoot } from './AppRoot';

afterEach(cleanup);

describe('@spec WEB-9.1 AppRoot width branch', () => {
  it('renders the compact Outlet below the breakpoint', () => {
    isDesktop.value = false;
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('compact-child')).toBeTruthy();
    expect(screen.queryByTestId('desktop-shell')).toBeNull();
  });
  it('renders the DesktopShell at or above the breakpoint', () => {
    isDesktop.value = true;
    render(<AppRoot><div data-testid="compact-child" /></AppRoot>);
    expect(screen.getByTestId('desktop-shell')).toBeTruthy();
    expect(screen.queryByTestId('compact-child')).toBeNull();
  });
});

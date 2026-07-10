import type { ReactNode } from 'react';
import { useRouterState } from '@tanstack/react-router';
import { useIsDesktop } from '../hooks/useIsDesktop';
import { DesktopShell } from './DesktopShell';

export function AppRoot({ children }: { children: ReactNode }) {
  const isDesktop = useIsDesktop();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  if (isDesktop && pathname !== '/new') return <DesktopShell />;
  return <>{children}</>;
}

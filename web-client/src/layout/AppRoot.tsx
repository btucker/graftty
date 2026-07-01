import type { ReactNode } from 'react';
import { useIsDesktop } from '../hooks/useIsDesktop';
import { DesktopShell } from './DesktopShell';

export function AppRoot({ children }: { children: ReactNode }) {
  return useIsDesktop() ? <DesktopShell /> : <>{children}</>;
}

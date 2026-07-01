import { Outlet } from '@tanstack/react-router';
import { AppRoot } from '../layout/AppRoot';

export function RootLayout() {
  return (
    <div id="app">
      <AppRoot>
        <Outlet />
      </AppRoot>
    </div>
  );
}

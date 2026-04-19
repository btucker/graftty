import { createRouter, createRootRoute, createRoute } from '@tanstack/react-router';
import { RootLayout } from './routes/__root';
import { IndexPage } from './routes/index';
import { SessionPage } from './routes/session.$name';

const rootRoute = createRootRoute({ component: RootLayout });

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/',
  component: IndexPage,
});

const sessionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/session/$name',
  component: SessionPage,
});

const routeTree = rootRoute.addChildren([indexRoute, sessionRoute]);

export const router = createRouter({ routeTree });

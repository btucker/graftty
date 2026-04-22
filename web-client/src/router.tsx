import { createRouter, createRootRoute, createRoute } from '@tanstack/react-router';
import { RootLayout } from './routes/__root';
import { IndexPage } from './routes/index';
import { SessionPage } from './routes/session.$name';
import { NewWorktreePage } from './routes/new';

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

const newWorktreeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/new',
  component: NewWorktreePage,
});

const routeTree = rootRoute.addChildren([indexRoute, sessionRoute, newWorktreeRoute]);

export const router = createRouter({ routeTree });

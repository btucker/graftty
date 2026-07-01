import { useParams } from '@tanstack/react-router';
import { useWorktreePanes } from '../hooks/useWorktreePanes';
import { PaneOverview } from '../panes/PaneOverview';

export function WorktreeDetailPage() {
  const { path } = useParams({ from: '/worktree/$path' });
  const worktreePath = decodeURIComponent(path);
  const state = useWorktreePanes();
  const worktree = state.kind === 'ready'
    ? state.worktrees.find((w) => w.path === worktreePath) ?? null
    : null;
  return <PaneOverview layout={worktree?.layout ?? null} />;
}

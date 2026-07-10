import { Link, useNavigate } from '@tanstack/react-router';
import { useWorktreePanes } from '../hooks/useWorktreePanes';
import { paneLeaves, type WorktreePanes } from '../paneTypes';

export function WorktreeListPage() {
  const state = useWorktreePanes();
  const navigate = useNavigate();
  if (state.kind === 'loading') return <div className="picker-status">loading…</div>;
  if (state.kind === 'error') return <div className="picker-status picker-error">error: {state.message}</div>;

  const open = (wt: WorktreePanes) => {
    const leaves = paneLeaves(wt.layout);
    if (leaves.length === 1) {
      void navigate({ to: '/session/$name', params: { name: leaves[0].sessionName } });
    } else {
      void navigate({ to: '/worktree/$path', params: { path: encodeURIComponent(wt.path) } });
    }
  };

  return (
    <div className="picker">
      <div className="picker-header">
        <h1>Graftty worktrees</h1>
        <Link to="/new" className="picker-add-worktree">+ Add worktree</Link>
      </div>
      {state.groups.map((group) => (
        <section key={group.repoDisplayName} className="picker-repo">
          <h2>{group.repoDisplayName}</h2>
          <ul>
            {group.worktrees.map((wt) => (
              <li key={wt.path}>
                <button type="button" className="picker-session" onClick={() => open(wt)}>
                  <span className="picker-label">{wt.displayName}</span>
                  <span className="picker-path">{wt.displayBranch}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

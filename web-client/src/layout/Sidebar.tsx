import { paneLeaves, displayTitle, type WorktreePanes } from '../paneTypes';
import type { RepoGroup } from '../hooks/useWorktreePanes';

export interface SidebarProps {
  groups: RepoGroup[];
  selectedPath: string | null;
  focusedSessionName: string | null;
  onSelectWorktree: (path: string) => void;
  onSelectPane: (worktreePath: string, sessionName: string) => void;
}

function divergence(wt: WorktreePanes): string | null {
  if (!wt.stats) return null;
  const { ahead, behind } = wt.stats;
  if (ahead === 0 && behind === 0) return null;
  return `↑${ahead} ↓${behind}`;
}

export function Sidebar({ groups, selectedPath, focusedSessionName, onSelectWorktree, onSelectPane }: SidebarProps) {
  return (
    <nav className="sidebar">
      {groups.map((group) => (
        <section key={group.repoDisplayName} className="sidebar-repo">
          <h2>{group.repoDisplayName}</h2>
          {group.worktrees.map((wt) => {
            const active = wt.path === selectedPath;
            const div = divergence(wt);
            return (
              <div key={wt.path} className="wt-block" data-active={active}>
                <button type="button" className="wt-row" data-active={active} onClick={() => onSelectWorktree(wt.path)}>
                  <span className="wt-name" data-main={wt.isMainCheckout}>{wt.displayName}</span>
                  {wt.displayBranch && wt.displayBranch !== wt.displayName
                    ? <span className="wt-branch">{wt.displayBranch}</span> : null}
                  {wt.prBadge ? <span className="wt-pr" data-checks={wt.prBadge.checks}>#{wt.prBadge.number}</span> : null}
                  {div ? <span className="wt-divergence">{div}</span> : null}
                  {wt.attentionText ? <span className="wt-attention">{wt.attentionText}</span> : null}
                </button>
                {active && wt.state === 'running'
                  ? paneLeaves(wt.layout).map((leaf) => (
                      <button
                        key={leaf.sessionName}
                        type="button"
                        className="pane-row"
                        data-busy={leaf.isBusy}
                        data-focused={focusedSessionName === leaf.sessionName}
                        onClick={() => onSelectPane(wt.path, leaf.sessionName)}
                      >
                        <span className="pane-glyph">↳</span>
                        <span className="pane-title">{displayTitle(leaf)}</span>
                        {leaf.attentionText ? <span className="pane-attention">{leaf.attentionText}</span> : null}
                      </button>
                    ))
                  : null}
              </div>
            );
          })}
        </section>
      ))}
    </nav>
  );
}

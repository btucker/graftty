// web-client/src/layout/DesktopShell.tsx
import { useEffect, useMemo, useState } from 'react';
import { Sidebar } from './Sidebar';
import { SplitLayout } from '../panes/SplitLayout';
import { TerminalPane } from '../components/TerminalPane';
import { paneLeaves, type PaneLeaf, type WorktreePanes } from '../paneTypes';
import { useWorktreePanes } from '../hooks/useWorktreePanes';

function firstWorktree(groups: { worktrees: WorktreePanes[] }[]): WorktreePanes | null {
  for (const g of groups) if (g.worktrees.length) return g.worktrees[0];
  return null;
}

function InteractivePaneTile({ leaf, focused, onFocus }: { leaf: PaneLeaf; focused: boolean; onFocus: () => void }) {
  return (
    <div className="pane-tile" data-focused={focused} onMouseDown={onFocus}
         style={{ width: '100%', height: '100%' }}>
      <TerminalPane sessionName={leaf.sessionName} role="interactive" fit="container" autoFocus={focused} />
    </div>
  );
}

export function DesktopShell() {
  const state = useWorktreePanes();
  const groups = state.kind === 'ready' ? state.groups : [];
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [focusedSessionName, setFocusedSessionName] = useState<string | null>(null);

  const selected = useMemo<WorktreePanes | null>(() => {
    const all = groups.flatMap((g) => g.worktrees);
    return all.find((w) => w.path === selectedPath) ?? firstWorktree(groups);
  }, [groups, selectedPath]);

  useEffect(() => {
    if (!selected) return;
    const leaves = paneLeaves(selected.layout);
    if (!leaves.some((l) => l.sessionName === focusedSessionName)) {
      setFocusedSessionName(leaves[0]?.sessionName ?? null);
    }
  }, [selected, focusedSessionName]);

  function handleMainMouseDown(e: React.MouseEvent) {
    const slot = (e.target as Element).closest?.('[data-session]');
    if (slot) {
      const session = slot.getAttribute('data-session');
      if (session) setFocusedSessionName(session);
    }
  }

  return (
    <div className="desktop-shell">
      <Sidebar
        groups={groups}
        selectedPath={selected?.path ?? null}
        focusedSessionName={focusedSessionName}
        onSelectWorktree={setSelectedPath}
        onSelectPane={(path, session) => { setSelectedPath(path); setFocusedSessionName(session); }}
      />
      <main className="desktop-content" onMouseDown={handleMainMouseDown}>
        {selected?.layout
          ? <SplitLayout
              node={selected.layout}
              renderLeaf={(leaf) => (
                <InteractivePaneTile
                  leaf={leaf}
                  focused={focusedSessionName === leaf.sessionName}
                  onFocus={() => setFocusedSessionName(leaf.sessionName)}
                />
              )}
            />
          : <div className="desktop-empty">select a worktree</div>}
      </main>
    </div>
  );
}

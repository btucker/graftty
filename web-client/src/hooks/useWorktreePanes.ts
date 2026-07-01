import { useEffect, useRef, useState } from 'react';
import { parseWorktreePanes, type WorktreePanes } from '../paneTypes';

export interface RepoGroup {
  repoDisplayName: string;
  worktrees: WorktreePanes[];
}

export type WorktreePanesState =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; groups: RepoGroup[]; worktrees: WorktreePanes[] };

export function groupByRepo(worktrees: WorktreePanes[]): RepoGroup[] {
  const order: string[] = [];
  const byRepo = new Map<string, WorktreePanes[]>();
  for (const wt of worktrees) {
    const key = wt.repoDisplayName;
    if (!byRepo.has(key)) { byRepo.set(key, []); order.push(key); }
    byRepo.get(key)!.push(wt);
  }
  return order.map((repoDisplayName) => ({ repoDisplayName, worktrees: byRepo.get(repoDisplayName)! }));
}

export function useWorktreePanes(pollMs = 2000): WorktreePanesState {
  const [state, setState] = useState<WorktreePanesState>({ kind: 'loading' });
  const haveDataRef = useRef(false);
  const lastRawRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const poll = async () => {
      try {
        const res = await fetch('/worktrees/panes', { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`/worktrees/panes → ${res.status}`);
        const json = await res.json();
        if (cancelled) return;
        const raw = JSON.stringify(json);
        haveDataRef.current = true;
        if (raw === lastRawRef.current) return;      // unchanged — skip re-render
        lastRawRef.current = raw;
        const worktrees = parseWorktreePanes(json);
        setState({ kind: 'ready', groups: groupByRepo(worktrees), worktrees });
      } catch (err) {
        if (cancelled || haveDataRef.current) return; // keep last-good data
        setState({ kind: 'error', message: err instanceof Error ? err.message : String(err) });
      }
    };
    void poll();
    const timer = setInterval(poll, pollMs);
    return () => { cancelled = true; clearInterval(timer); };
  }, [pollMs]);

  return state;
}

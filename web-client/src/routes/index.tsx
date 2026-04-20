import { useEffect, useState } from 'react';
import { Link, useNavigate } from '@tanstack/react-router';

interface SessionInfo {
  name: string;
  worktreePath: string;
  repoDisplayName: string;
  worktreeDisplayName: string;
}

type FetchState =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; sessions: SessionInfo[] };

export function IndexPage() {
  const navigate = useNavigate();
  const [state, setState] = useState<FetchState>({ kind: 'loading' });

  // Legacy `?session=<name>` redirect — kept for any old Copy-URL output
  // that users might have bookmarked.
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const session = params.get('session');
    if (session) {
      void navigate({ to: '/session/$name', params: { name: session }, replace: true });
    }
  }, [navigate]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch('/sessions', { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`/sessions → ${res.status}`);
        const data = (await res.json()) as SessionInfo[];
        if (!cancelled) setState({ kind: 'ready', sessions: data });
      } catch (err) {
        if (!cancelled) {
          setState({
            kind: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (state.kind === 'loading') {
    return <div className="picker-status">loading sessions…</div>;
  }
  if (state.kind === 'error') {
    return <div className="picker-status picker-error">error: {state.message}</div>;
  }
  if (state.sessions.length === 0) {
    return (
      <div className="picker-status">
        No running sessions. Start one in Espalier.
      </div>
    );
  }

  // Group by repoDisplayName so the list mirrors the sidebar shape.
  const grouped = new Map<string, SessionInfo[]>();
  for (const s of state.sessions) {
    const key = s.repoDisplayName;
    const arr = grouped.get(key) ?? [];
    arr.push(s);
    grouped.set(key, arr);
  }

  return (
    <div className="picker">
      <h1>Espalier sessions</h1>
      {[...grouped.entries()].map(([repo, sessions]) => (
        <section key={repo} className="picker-repo">
          <h2>{repo}</h2>
          <ul>
            {sessions.map((s) => (
              <li key={s.name}>
                <Link
                  to="/session/$name"
                  params={{ name: s.name }}
                  className="picker-session"
                >
                  <span className="picker-label">{s.worktreeDisplayName}</span>
                  <span className="picker-path">{s.worktreePath}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, Link } from '@tanstack/react-router';
import { sanitizeWorktreeName, trimForSubmit } from '../sanitizeWorktreeName';

interface RepoInfo {
  path: string;
  displayName: string;
}

interface CreateResponse {
  sessionName: string;
  worktreePath: string;
}

type ReposState =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; repos: RepoInfo[] };

/// Web parallel of `Sources/Graftty/Views/AddWorktreeSheet.swift`.
/// Parity notes:
/// - Branch field defaults to mirror the worktree name until the user
///   types something different in the branch field, after which it
///   stops auto-syncing.
/// - Input is sanitized live via the shared `sanitizeWorktreeName` port
///   so pasting `my feature/foo!` immediately becomes `my-feature-foo-`.
/// - Trim-on-submit strips leading/trailing whitespace, dashes, and
///   dots (matches the Swift `submitTrimSet`).
export function NewWorktreePage() {
  const navigate = useNavigate();
  const [reposState, setReposState] = useState<ReposState>({ kind: 'loading' });
  const [selectedRepo, setSelectedRepo] = useState<string>('');
  const [worktreeName, setWorktreeName] = useState<string>('');
  const [branchName, setBranchName] = useState<string>('');
  const [branchMirrors, setBranchMirrors] = useState<boolean>(true);
  const [submitting, setSubmitting] = useState<boolean>(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch('/repos', { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`/repos → ${res.status}`);
        const repos = (await res.json()) as RepoInfo[];
        if (cancelled) return;
        setReposState({ kind: 'ready', repos });
        if (repos.length > 0) setSelectedRepo(repos[0].path);
      } catch (err) {
        if (!cancelled) {
          setReposState({
            kind: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const handleWorktreeNameChange = (raw: string) => {
    const sanitized = sanitizeWorktreeName(raw);
    setWorktreeName(sanitized);
    if (branchMirrors) setBranchName(sanitized);
  };

  const handleBranchNameChange = (raw: string) => {
    const sanitized = sanitizeWorktreeName(raw);
    setBranchName(sanitized);
    if (sanitized !== worktreeName) setBranchMirrors(false);
  };

  const canSubmit = useMemo(() => {
    if (submitting) return false;
    if (!selectedRepo) return false;
    return trimForSubmit(worktreeName).length > 0 &&
           trimForSubmit(branchName).length > 0;
  }, [submitting, selectedRepo, worktreeName, branchName]);

  const selectedRepoInfo = useMemo(() => {
    if (reposState.kind !== 'ready') return null;
    return reposState.repos.find((r) => r.path === selectedRepo) ?? null;
  }, [reposState, selectedRepo]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canSubmit) return;
    setErrorMessage(null);
    setSubmitting(true);
    try {
      const body = {
        repoPath: selectedRepo,
        worktreeName: trimForSubmit(worktreeName),
        branchName: trimForSubmit(branchName),
      };
      const res = await fetch('/worktrees', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        // The server always returns JSON with {error}. Fall back to a
        // generic message if the body is unparseable so we never show
        // "[object Object]" in the red strip.
        let msg = `request failed (${res.status})`;
        try {
          const err = (await res.json()) as { error?: string };
          if (err.error) msg = err.error;
        } catch { /* keep fallback */ }
        setErrorMessage(msg);
        setSubmitting(false);
        return;
      }
      const payload = (await res.json()) as CreateResponse;
      void navigate({
        to: '/session/$name',
        params: { name: payload.sessionName },
      });
    } catch (err) {
      setErrorMessage(err instanceof Error ? err.message : String(err));
      setSubmitting(false);
    }
  };

  if (reposState.kind === 'loading') {
    return <div className="picker-status">loading repositories…</div>;
  }
  if (reposState.kind === 'error') {
    return <div className="picker-status picker-error">error: {reposState.message}</div>;
  }
  if (reposState.repos.length === 0) {
    return (
      <div className="picker">
        <h1>Add worktree</h1>
        <div className="picker-status">
          No repositories tracked. Open one in Graftty first.
        </div>
        <Link className="new-worktree-back" to="/">← Back to sessions</Link>
      </div>
    );
  }

  return (
    <div className="picker">
      <h1>
        Add worktree
        {selectedRepoInfo ? <> to <span className="new-worktree-repo">{selectedRepoInfo.displayName}</span></> : null}
      </h1>
      <form className="new-worktree-form" onSubmit={handleSubmit}>
        {reposState.repos.length > 1 && (
          <label className="new-worktree-field">
            <span>Repository</span>
            <select
              value={selectedRepo}
              onChange={(e) => setSelectedRepo(e.target.value)}
              disabled={submitting}
            >
              {reposState.repos.map((r) => (
                <option key={r.path} value={r.path}>{r.displayName}</option>
              ))}
            </select>
          </label>
        )}
        <label className="new-worktree-field">
          <span>Worktree name</span>
          <input
            type="text"
            value={worktreeName}
            placeholder="feature-xyz"
            autoFocus
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            disabled={submitting}
            onChange={(e) => handleWorktreeNameChange(e.target.value)}
          />
        </label>
        <label className="new-worktree-field">
          <span>Branch</span>
          <input
            type="text"
            value={branchName}
            placeholder="feature-xyz"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            disabled={submitting}
            onChange={(e) => handleBranchNameChange(e.target.value)}
          />
        </label>
        {errorMessage && (
          <div className="new-worktree-error">{errorMessage}</div>
        )}
        <div className="new-worktree-actions">
          <Link to="/" className="new-worktree-cancel">Cancel</Link>
          <button
            type="submit"
            className="new-worktree-submit"
            disabled={!canSubmit}
          >
            {submitting ? 'Creating…' : 'Create'}
          </button>
        </div>
      </form>
    </div>
  );
}

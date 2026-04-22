// Port of Swift's `WorktreeNameSanitizer.sanitize`
// (Sources/GrafttyKit/Git/WorktreeNameSanitizer.swift). Keep the two in
// lock-step: any allowed-set change there must be mirrored here so
// web-created and native-created worktrees end up with identical
// identifiers.
//
// Allowed set: `A-Z a-z 0-9 . _ - /`. Everything else — including any
// non-ASCII — collapses to a single `-`. Consecutive disallowed chars
// collapse to one dash rather than running on, so `my feature!` becomes
// `my-feature-` rather than `my--feature--`. We do not trim leading or
// trailing dashes here; that would swallow the separator between the
// word the user already typed and the word they're about to type. The
// submit path trims before sending.
export function sanitizeWorktreeName(input: string): string {
  let out = '';
  let lastWasDash = false;
  for (const ch of input) {
    if (isAllowed(ch)) {
      if (ch === '-') {
        if (!lastWasDash) {
          out += '-';
          lastWasDash = true;
        }
      } else {
        out += ch;
        lastWasDash = false;
      }
    } else if (!lastWasDash) {
      out += '-';
      lastWasDash = true;
    }
  }
  return out;
}

function isAllowed(ch: string): boolean {
  if (ch.length !== 1) return false;
  const code = ch.charCodeAt(0);
  // 0-9: 48-57 | A-Z: 65-90 | a-z: 97-122
  if ((code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122)) return true;
  return ch === '.' || ch === '_' || ch === '-' || ch === '/';
}

/// Chars trimmed off either end on submit. Mirrors the Swift side's
/// `submitTrimSet` (whitespace + `-` + `.`) — a leading/trailing dash or
/// dot is never what the user wants, and git rejects a leading `.`
/// anyway.
export function trimForSubmit(s: string): string {
  return s.replace(/^[\s\-.]+|[\s\-.]+$/g, '');
}

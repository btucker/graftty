#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Fail when a test file silently skips Linux because Package.swift forgot it.

Test targets that declare `sources: isLinux ? [ ... ] : nil` compile only the
listed files on Linux. A new portable test that is not added to that list never
runs on the only platform that ships `graftty-host`, and CI stays green (#529).

For every target using that pattern, each `*.swift` under `Tests/<target>` must
be exactly one of:

- listed (directly or via a listed directory) in the target's Linux `sources:`
  allowlist;
- marked Apple-only: an `#if os(macOS)` / `#if os(iOS)` /
  `#if canImport(AppKit)` / `#if canImport(UIKit)` (or an `||` of those) that
  opens at the first line that is not a comment or import and closes at the
  end of the file with no `#else` / `#elseif` branch, or a path under an
  `Apple/` directory;
- named in `scripts/linux-test-allowlist-apple-only.txt`, the baseline of files
  that were unlisted and unmarked (so never compiled on Linux) when this check
  landed. Most were never checked for portability.

Listed paths and baseline entries that no longer exist also fail, as do listed
files that are marked Apple-only and so compile to nothing on Linux.

CI runs this in the `verify-specs` job.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASELINE_PATH = REPO_ROOT / "scripts" / "linux-test-allowlist-apple-only.txt"

# `name: "X"` followed, within the same target, by the Linux allowlist.
_ALLOWLIST_RE = re.compile(
    r'name:\s*"(?P<name>[^"]+)"'
    r'(?:(?!\.(?:\w*[tT]arget|plugin|macro|systemLibrary)\().)*?'
    r'sources:\s*isLinux\s*\?\s*\[(?P<entries>[^\]]*)\]\s*:\s*nil',
    re.DOTALL,
)
_APPLE_CONDITION_RE = re.compile(r"(?:os\((?:macOS|iOS)\)|canImport\((?:AppKit|UIKit)\))")
_IF_RE = re.compile(r"#if\s+(?P<condition>.+)")
_IMPORT_RE = re.compile(r"(?:@\w+(?:\([^)]*\))?\s+)*import\s")
# One pass, leftmost first, so a `/*` inside a `//` comment (or vice versa) is
# consumed by the comment that opened first.
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


def parse_allowlists(package_text: str) -> dict[str, list[str]]:
    """Map each target using `sources: isLinux ? [...] : nil` to its entries."""
    allowlists: dict[str, list[str]] = {}
    for match in _ALLOWLIST_RE.finditer(package_text):
        entries = re.sub(r"//[^\n]*", "", match["entries"])
        allowlists[match["name"]] = re.findall(r'"([^"]+)"', entries)
    return allowlists


def _is_apple_only_if(line: str) -> bool:
    """`#if` whose every `||` disjunct starts with an Apple-only condition."""
    match = _IF_RE.fullmatch(line)
    return bool(match) and all(_APPLE_CONDITION_RE.match(part.strip()) for part in match["condition"].split("||"))


def has_apple_only_guard(swift_text: str) -> bool:
    """True when an Apple-only `#if` opens at the first non-import code line and
    closes at the end of the file with no `#else` / `#elseif` branch."""
    stripped = _COMMENT_RE.sub(lambda m: "\n" * m[0].count("\n"), swift_text)
    code = [line for raw in stripped.splitlines() if (line := raw.strip())]
    start = next((i for i, line in enumerate(code) if not _IMPORT_RE.match(line)), None)
    if start is None or not _is_apple_only_if(code[start]):
        return False
    depth = 0
    for i in range(start, len(code)):
        line = code[i]
        if line.startswith("#if"):
            depth += 1
        elif line.startswith("#endif"):
            depth -= 1
            if depth == 0:
                return i == len(code) - 1
        elif depth == 1 and line.startswith("#else"):
            return False
    return False


def parse_baseline(text: str) -> set[str]:
    return {entry for line in text.splitlines() if (entry := line.split("#", 1)[0].strip())}


def load_baseline(path: Path) -> set[str]:
    return parse_baseline(path.read_text()) if path.exists() else set()


def _under_apple_dir(rel: str) -> bool:
    return "Apple" in Path(rel).parts[:-1]


def _is_listed(rel: str, listed: set[str]) -> bool:
    """SwiftPM `sources:` entries may name a file or a directory."""
    return rel in listed or any(rel.startswith(entry.rstrip("/") + "/") for entry in listed)


def check_tree(root: Path, baseline: set[str]) -> list[str]:
    """Return one human-readable problem per offending path (empty = clean)."""
    problems: list[str] = []
    allowlists = parse_allowlists((root / "Package.swift").read_text())
    seen_baseline: set[str] = set()

    for target, entries in allowlists.items():
        target_dir = root / "Tests" / target
        prefix = f"Tests/{target}/"
        if not target_dir.is_dir():
            problems.append(f"{prefix}: target {target} uses the Linux `sources:` allowlist but its directory is missing")
            continue
        listed = set(entries)
        for entry in sorted(listed):
            if not (target_dir / entry).exists():
                problems.append(f"{prefix}{entry}: listed in the {target} Linux `sources:` allowlist but does not exist; remove it from Package.swift")

        for file in sorted(target_dir.rglob("*.swift")):
            rel = file.relative_to(target_dir).as_posix()
            path = prefix + rel
            if path in baseline:
                seen_baseline.add(path)
            if _is_listed(rel, listed):
                if _under_apple_dir(rel):
                    problems.append(f"{path}: listed in the {target} Linux `sources:` allowlist but lives under an Apple/ directory; move it out or unlist it")
                elif has_apple_only_guard(file.read_text()):
                    problems.append(f"{path}: listed in the {target} Linux `sources:` allowlist but wrapped in an Apple-only `#if`, so it compiles to nothing on Linux; remove the guard or unlist it")
                elif path in baseline:
                    problems.append(f"{path}: listed in the {target} Linux `sources:` allowlist and in the Apple-only baseline; remove it from {BASELINE_PATH.name}")
                continue
            marked = _under_apple_dir(rel) or has_apple_only_guard(file.read_text())
            if marked and path in baseline:
                problems.append(f"{path}: already marked Apple-only; remove it from {BASELINE_PATH.name}")
            elif not marked and path not in baseline:
                problems.append(
                    f"{path}: not in the Linux `sources:` allowlist for {target}, so it never runs on Linux. "
                    f"If it is portable, add \"{rel}\" to that list in Package.swift; if it needs AppKit/UIKit, "
                    f"wrap it in a file-level `#if os(macOS)` (or `#if canImport(AppKit)`)."
                )

    for path in sorted(baseline - seen_baseline):
        reason = "is not under a target that uses the allowlist" if (root / path).is_file() else "does not exist"
        problems.append(f"{path}: named in the Apple-only baseline {BASELINE_PATH.name} but {reason}; remove it")
    return problems


def main() -> int:
    problems = check_tree(REPO_ROOT, load_baseline(BASELINE_PATH))
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"\n{len(problems)} Linux test allowlist problem(s); see scripts/check-linux-test-allowlist.py.", file=sys.stderr)
        return 1
    print("Linux test allowlists are complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

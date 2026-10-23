#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Fail when a test file silently skips Linux because Package.swift drifted.

`graftty-host` ships only on Linux, so a portable test that never compiles
there leaves CI green while the host goes untested (#529, #477). Package.swift
expresses Linux test membership in three ways; each gets its own check:

- `exclude: isLinux ? [ ... ] (+ name) : []` or `exclude: isLinux ? name : []`
  (GrafttyKitTests, GrafttyProtocolTests, GrafttyKit): every file compiles on
  Linux unless excluded. `name` is a `let name = [ ... ]` array, such as
  GrafttyKitTests' `linuxPendingKitTests` (files not yet ported to Linux).
  Every excluded path must exist and must not be redundant: covered by
  another excluded directory (`Apple/Sub` next to `Apple`), or Apple-only
  already (a whole-file Apple `#if`, or a directory whose every Swift file
  is wrapped in one).
- `sources: isLinux ? [ ... ] : nil`: only the listed files compile on
  Linux. Each `*.swift` under the target must be listed or marked
  Apple-only, every listed path must exist, and a listed file must not be
  marked Apple-only.
- `sources: [ ... ]` on a Linux-only target (GrafttyDirectSSHTests): every
  listed path must exist and must not be wrapped in an Apple-only `#if`.

Comments are ignored. Any other `isLinux` expression inside a target
(grouping, another shape, a second argument), or a referenced constant that
is not a single array literal, is an error, so a target cannot drop out of
the check silently.

A target's directory is its `path:` when given, else `Tests/<name>` for a test
target and `Sources/<name>` otherwise.

An Apple-only guard is an `#if os(macOS)` / `#if os(iOS)` /
`#if canImport(AppKit)` / `#if canImport(UIKit)` (or an `||` of those) that
opens at the first line that is not a comment or import and closes at the end
of the file with no `#else` / `#elseif` branch.

CI runs this in the `verify-specs` job.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

_TARGET_START_RE = re.compile(r"\.(?P<kind>\w*[tT]arget|plugin|macro|systemLibrary)\(")
_NAME_RE = re.compile(r'name:\s*"(?P<name>[^"]+)"')
_PATH_RE = re.compile(r'\bpath:\s*"(?P<path>[^"]+)"')
_LINUX_SOURCES_RE = re.compile(r"\bsources:\s*isLinux\s*\?\s*\[(?P<entries>[^\]]*)\]\s*:\s*nil(?=\s*[,)])")
_FIXED_SOURCES_RE = re.compile(r"\bsources:\s*\[(?P<entries>[^\]]*)\]")
_LINUX_EXCLUDE_RE = re.compile(
    r"\bexclude:\s*isLinux\s*\?\s*"
    r"(?:\[(?P<entries>[^\]]*)\]\s*(?:\+\s*(?P<ref>\w+)\s*)?|(?P<bare_ref>\w+)\s*)"
    r":\s*\[\s*\](?=\s*[,)])"
)
_APPLE_CONDITION_RE = re.compile(r"(?:os\((?:macOS|iOS)\)|canImport\((?:AppKit|UIKit)\))")
_IF_RE = re.compile(r"#if\s+(?P<condition>.+)")
_IMPORT_RE = re.compile(r"(?:@\w+(?:\([^)]*\))?\s+)*import\s")
# One pass, leftmost first, so a `/*` inside a `//` comment (or vice versa) is
# consumed by the comment that opened first.
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


@dataclass
class TargetLinuxMembership:
    name: str
    directory: str
    linux_sources: list[str] | None = None
    linux_exclude: list[str] = field(default_factory=list)
    fixed_sources: list[str] | None = None


def strip_swift_comments(text: str) -> str:
    """Blank out `//` and (nested) `/* */` comments, leaving string literals,
    including multi-line ones, intact. Newlines survive, so offsets and line
    structure are preserved."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append(text[i:end]); i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i)); i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1; j += 2
                elif text.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append("".join(c if c == "\n" else " " for c in text[i:j])); i = j
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def _matching_paren(text: str, open_index: int) -> int:
    """Index just past the `)` closing the `(` at `open_index` (comment-free
    text), skipping string literals."""
    depth, i, n = 0, open_index, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _strings(text: str) -> list[str]:
    return re.findall(r'"([^"]+)"', text)


def parse_array_constants(package_text: str) -> dict[str, list[str] | None]:
    """`let name = [ "a", "b" ]` string-array constants, by name. A constant
    whose initializer continues past the literal (`[...] + other`,
    `.filter { }`) maps to None: it cannot be resolved statically."""
    constants: dict[str, list[str] | None] = {}
    for m in re.finditer(r"\blet\s+(?P<name>\w+)\s*(?::[^=]+)?=\s*\[(?P<body>[^\]]*)\]", package_text):
        # The initializer continues if the next token, even on a later line,
        # is an operator or member access (`+ [...]`, `.map { }`).
        continued = re.match(r"\s*[-+*/%&|^?.!<>=]", package_text[m.end():])
        constants[m["name"]] = None if continued else _strings(m["body"])
    return constants


def parse_targets(package_text: str) -> list[TargetLinuxMembership]:
    """Every target that declares how its files compile on Linux. Comments are
    ignored, a target's block runs to its closing parenthesis (so a nested
    `.target(name:)` dependency stays inside its owner), and an `isLinux`
    membership expression this parser does not understand is an error rather
    than a silently unchecked target."""
    package_text = strip_swift_comments(package_text)
    constants = parse_array_constants(package_text)
    targets: list[TargetLinuxMembership] = []
    block_end = 0
    for match in _TARGET_START_RE.finditer(package_text):
        if match.start() < block_end:
            continue
        block_end = _matching_paren(package_text, match.end() - 1)
        block = package_text[match.end():block_end]
        name = _NAME_RE.search(block)
        if not name:
            continue
        path = _PATH_RE.search(block)
        default_root = "Tests" if match["kind"] == "testTarget" else "Sources"
        target = TargetLinuxMembership(name["name"], path["path"] if path else f"{default_root}/{name['name']}")
        recognized: list[re.Match[str]] = []
        if linux_sources := _LINUX_SOURCES_RE.search(block):
            target.linux_sources = _strings(linux_sources["entries"])
            recognized.append(linux_sources)
        elif fixed := _FIXED_SOURCES_RE.search(block):
            target.fixed_sources = _strings(fixed["entries"])
        if exclude := _LINUX_EXCLUDE_RE.search(block):
            recognized.append(exclude)
            target.linux_exclude = _strings(exclude["entries"] or "")
            if ref := exclude["ref"] or exclude["bare_ref"]:
                if ref not in constants:
                    raise ValueError(f"{name['name']}: Linux exclude references unknown array `{ref}`")
                if (values := constants[ref]) is None:
                    raise ValueError(f"{name['name']}: Linux exclude references `{ref}`, whose initializer is not a single array literal")
                target.linux_exclude += values
        # Fail closed: any `isLinux` the recognized arguments did not consume
        # (grouping, a second unsupported argument, another shape) is an error.
        remainder = block
        for m in sorted(recognized, key=lambda m: m.start(), reverse=True):
            remainder = remainder[:m.start()] + remainder[m.end():]
        if re.search(r"\bisLinux\b", remainder):
            raise ValueError(f"{name['name']}: unsupported `isLinux` expression in target; see scripts/check-linux-test-allowlist.py")
        if target.linux_sources is not None or target.fixed_sources is not None or target.linux_exclude:
            targets.append(target)
    return targets


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


def _under_apple_dir(rel: str) -> bool:
    return "Apple" in Path(rel).parts[:-1]


def _covers(rel: str, entries: set[str]) -> bool:
    """SwiftPM `sources:` / `exclude:` entries may name a file or a directory."""
    return rel in entries or any(rel.startswith(entry.rstrip("/") + "/") for entry in entries)


def _check_entries_exist(target: TargetLinuxMembership, root: Path, entries: list[str], kind: str) -> list[str]:
    return [
        f"{target.directory}/{entry}: in the {target.name} Linux {kind} but does not exist; remove it from Package.swift"
        for entry in sorted(set(entries))
        if not (root / target.directory / entry).exists()
    ]


def check_target(target: TargetLinuxMembership, root: Path) -> list[str]:
    target_dir = root / target.directory
    if not target_dir.is_dir():
        return [f"{target.directory}: directory of target {target.name} is missing"]
    problems: list[str] = []

    if target.linux_exclude:
        problems += _check_entries_exist(target, root, target.linux_exclude, "`exclude:` list")
        entries = set(target.linux_exclude)
        for entry in sorted(entries):
            item = target_dir / entry
            path = f"{target.directory}/{entry}"
            ancestors = [other for other in entries if other != entry and _covers(entry, {other})]
            if ancestors:
                problems.append(f"{path}: excluded on Linux but already covered by `{ancestors[0]}`; remove it from the {target.name} exclude list")
            elif item.is_file() and item.suffix == ".swift" and has_apple_only_guard(item.read_text()):
                problems.append(f"{path}: excluded on Linux but already wrapped in an Apple-only `#if`; remove it from the {target.name} exclude list")
            elif item.is_dir():
                swift = sorted(item.rglob("*.swift"))
                if swift and all(has_apple_only_guard(f.read_text()) for f in swift):
                    problems.append(f"{path}: excluded on Linux but every Swift file in it is already wrapped in an Apple-only `#if`; remove it from the {target.name} exclude list")

    if target.linux_sources is not None:
        listed, excluded = set(target.linux_sources), set(target.linux_exclude)
        problems += _check_entries_exist(target, root, target.linux_sources, "`sources:` allowlist")
        for file in sorted(target_dir.rglob("*.swift")):
            rel = file.relative_to(target_dir).as_posix()
            path = f"{target.directory}/{rel}"
            if _covers(rel, excluded):
                continue
            marked = _under_apple_dir(rel) or has_apple_only_guard(file.read_text())
            if _covers(rel, listed):
                if _under_apple_dir(rel):
                    problems.append(f"{path}: listed in the {target.name} Linux `sources:` allowlist but lives under an Apple/ directory; move it out or unlist it")
                elif marked:
                    problems.append(f"{path}: listed in the {target.name} Linux `sources:` allowlist but wrapped in an Apple-only `#if`, so it compiles to nothing on Linux; remove the guard or unlist it")
            elif not marked:
                problems.append(
                    f"{path}: not in the Linux `sources:` allowlist for {target.name}, so it never runs on Linux. "
                    f"If it is portable, add \"{rel}\" to that list in Package.swift; if it needs AppKit/UIKit, "
                    f"wrap it in a file-level `#if os(macOS)` (or `#if canImport(AppKit)`)."
                )

    if target.fixed_sources is not None:
        problems += _check_entries_exist(target, root, target.fixed_sources, "`sources:` list")
        for entry in sorted(set(target.fixed_sources)):
            file = target_dir / entry
            if file.is_file() and file.suffix == ".swift" and has_apple_only_guard(file.read_text()):
                problems.append(f"{target.directory}/{entry}: listed in {target.name} `sources:` but wrapped in an Apple-only `#if`, so it compiles to nothing on Linux")
    return problems


def check_tree(root: Path) -> list[str]:
    """Return one human-readable problem per offending path (empty = clean)."""
    problems: list[str] = []
    for target in parse_targets((root / "Package.swift").read_text()):
        problems += check_target(target, root)
    return problems


def main() -> int:
    problems = check_tree(REPO_ROOT)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"\n{len(problems)} Linux test membership problem(s); see scripts/check-linux-test-allowlist.py.", file=sys.stderr)
        return 1
    print("Linux test membership is consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# TODO Spec Implementation Audit Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify every disabled `@spec` in `Tests/GrafttyTests/Specs/*Todo.swift` as either already implemented but untested, unimplemented, partially implemented, or policy/negative behavior that needs a different treatment.

**Architecture:** `SPECS.md` is now generated from `@spec` annotations; the source of truth for missing behavioral coverage is the disabled Swift Testing inventory under `Tests/GrafttyTests/Specs`. This plan creates an audit ledger first, backed by code/test evidence for each spec, then uses that ledger to decide which entries should be promoted into active tests and which should remain backlog implementation work.

**Tech Stack:** Swift 5.10, Swift Testing `@spec` annotations, `scripts/generate-specs.py`, `rg`, generated `SPECS.md`.

---

## Scope

There are 473 disabled TODO specs across 23 inventory files:

| Todo file | Count |
| --- | ---: |
| `Tests/GrafttyTests/Specs/AttnTodo.swift` | 27 |
| `Tests/GrafttyTests/Specs/BellTodo.swift` | 1 |
| `Tests/GrafttyTests/Specs/ChanTodo.swift` | 33 |
| `Tests/GrafttyTests/Specs/ConfigTodo.swift` | 7 |
| `Tests/GrafttyTests/Specs/DistTodo.swift` | 11 |
| `Tests/GrafttyTests/Specs/DivergeTodo.swift` | 20 |
| `Tests/GrafttyTests/Specs/GitTodo.swift` | 46 |
| `Tests/GrafttyTests/Specs/IosTodo.swift` | 46 |
| `Tests/GrafttyTests/Specs/KbdTodo.swift` | 8 |
| `Tests/GrafttyTests/Specs/KeyTodo.swift` | 9 |
| `Tests/GrafttyTests/Specs/LayoutTodo.swift` | 40 |
| `Tests/GrafttyTests/Specs/MouseTodo.swift` | 4 |
| `Tests/GrafttyTests/Specs/NotifTodo.swift` | 6 |
| `Tests/GrafttyTests/Specs/PersistTodo.swift` | 12 |
| `Tests/GrafttyTests/Specs/PrTodo.swift` | 24 |
| `Tests/GrafttyTests/Specs/PwdTodo.swift` | 12 |
| `Tests/GrafttyTests/Specs/StateTodo.swift` | 13 |
| `Tests/GrafttyTests/Specs/TeamTodo.swift` | 23 |
| `Tests/GrafttyTests/Specs/TechTodo.swift` | 5 |
| `Tests/GrafttyTests/Specs/TermTodo.swift` | 43 |
| `Tests/GrafttyTests/Specs/UpdateTodo.swift` | 12 |
| `Tests/GrafttyTests/Specs/WebTodo.swift` | 48 |
| `Tests/GrafttyTests/Specs/ZmxTodo.swift` | 23 |

The audit must not blindly trust `.disabled("not yet implemented")`. Some entries are probably already implemented but only lack active `@spec` tests, and some are negative/policy specs such as "shall not implement" or "removed" that should not be lumped into normal unimplemented work.

## Classification Rules

Use exactly these statuses in the audit ledger:

- `implemented-untested`: production behavior appears implemented, but the spec has no active behavioral `@spec` test. Next action is to promote/delete the TODO entry and add a real test.
- `unimplemented`: production behavior is absent or materially contradicts the spec. Next action is to leave the TODO entry and create a separate implementation plan.
- `partial`: some clauses are implemented, but the spec contains multiple obligations and at least one is missing. Next action is to split the spec or create targeted tests for the implemented clauses before implementation work.
- `policy-negative`: the spec describes intentional absence, removal, or "shall not implement" behavior. Next action is to decide whether it needs an active assertion, should become a doc/type `@spec`, or should be deleted.
- `ambiguous`: evidence is insufficient without a manual run, UI smoke, or stakeholder decision. Next action is to write the missing question and the smallest verification step.

For every status, record:

- `Spec ID`
- `Todo file`
- `Requirement summary`
- `Status`
- `Implementation evidence` with exact source paths and symbols
- `Existing test evidence` with exact active test paths, or `none`
- `Recommended next action`
- `Confidence` as `high`, `medium`, or `low`

## Files

- Create: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`
- Modify only if correcting stale planning: `docs/superpowers/plans/2026-04-30-todo-spec-implementation-audit.md`
- Do not modify production code or promote tests during this audit plan.
- Do not edit `SPECS.md` directly; it is generated.

## Task 1: Validate The Generated Spec Inventory

**Files:**
- Read: `CLAUDE.md`
- Read: `scripts/generate-specs.py`
- Read: `Tests/GrafttyTests/Specs/*Todo.swift`
- Create: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`

- [ ] **Step 1: Confirm spec generation is clean**

Run:

```bash
scripts/generate-specs.py --check
```

Expected: PASS. If it fails, stop and fix generation drift before classification; otherwise the audit can classify stale IDs.

- [ ] **Step 2: Create the audit ledger shell**

Create `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md` with:

```markdown
# TODO Spec Implementation Audit

Generated from disabled specs in `Tests/GrafttyTests/Specs/*Todo.swift`.

## Summary

| Status | Count |
| --- | ---: |
| implemented-untested | 0 |
| unimplemented | 0 |
| partial | 0 |
| policy-negative | 0 |
| ambiguous | 0 |

## Audit Rows

| Spec ID | Todo file | Requirement summary | Status | Implementation evidence | Existing test evidence | Recommended next action | Confidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
```

- [ ] **Step 3: Populate one row per disabled spec**

Use a small read-only extraction command to generate row stubs:

```bash
python3 - <<'PY'
from pathlib import Path
import re
for path in sorted(Path("Tests/GrafttyTests/Specs").glob("*Todo.swift")):
    text = path.read_text()
    for m in re.finditer(r"@spec\s+([A-Z]+-[0-9]+(?:\.[0-9]+)?)\s*:\s*(.*?)(?=\"\"\", \\.disabled)", text, re.S):
        spec_id = m.group(1)
        summary = " ".join(m.group(2).split())
        print(f"| `{spec_id}` | `{path}` | {summary[:160]} | `ambiguous` | TBD | none | Audit implementation evidence. | `low` |")
PY
```

Paste the generated rows under `## Audit Rows`.

- [ ] **Step 4: Commit only if this becomes a long-running audit branch**

```bash
git add docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md
git commit -m "docs(specs): add todo spec implementation audit ledger"
```

If the audit will be completed in one session, skip this commit until after classification.

## Task 2: Run A Mechanical Evidence Pass

**Files:**
- Modify: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`
- Read: `Tests/**/*Tests.swift`
- Read: `Sources/**/*.swift`

- [ ] **Step 1: For each TODO spec ID, search active tests**

Run examples:

```bash
rg -n "@spec GIT-3.13|GIT-3.13" Tests Sources -g '!Tests/GrafttyTests/Specs/*Todo.swift'
rg -n "@spec WEB-3.6|WEB-3.6|Content-Length|writeAndFlush" Tests Sources -g '!Tests/GrafttyTests/Specs/*Todo.swift'
```

Expected: If an active test has the same `@spec ID`, this is a generator invariant violation; normally active tests should not duplicate TODO entries. Related tests without the same ID are evidence, not coverage.

- [ ] **Step 2: Search source symbols and comments**

For each section, search by the noun phrases in the spec text, not just the ID. Examples:

```bash
rg -n "listen|backlog|maxPerClientBytes|GRAFTTY_SOCK|Attention|NotifySocket" Sources Tests/GrafttyKitTests Tests/GrafttyTests -g '!Tests/GrafttyTests/Specs/*Todo.swift'
rg -n "WorktreeReconciler|stale|stopWatchingWorktree|RemoteBranchStore|originRefs" Sources Tests/GrafttyKitTests -g '!Tests/GrafttyTests/Specs/*Todo.swift'
rg -n "WebServer|WebURLComposer|Tailscale|Content-Length|NWConnection|worktrees" Sources Tests/GrafttyKitTests web-client/src -g '!Tests/GrafttyTests/Specs/*Todo.swift'
```

Expected: Each row gets at least one concrete evidence note or a concrete "no matching implementation found" note.

- [ ] **Step 3: Update obvious implemented-untested rows**

If source code directly implements the requirement and related tests exist without the `@spec` ID, mark the row `implemented-untested`. Example pattern:

```markdown
| `WEB-3.6` | `Tests/GrafttyTests/Specs/WebTodo.swift` | Connection-close responses transmit declared body bytes. | `implemented-untested` | `Sources/GrafttyKit/Web/WebServer.swift:630` sets `Content-Length`; `:649-652` closes after flush promise. | `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift:131` URLSession body length check; no raw HTTPS active `@spec`. | Promote to raw HTTPS `@Test` and delete `web_3_6` TODO. | `high` |
```

- [ ] **Step 4: Update obvious unimplemented rows**

If no source path exists or the source plainly contradicts the spec, mark `unimplemented`. Do not invent implementation tasks in this audit row; record only the next action.

- [ ] **Step 5: Flag policy-negative rows instead of forcing a false binary**

Rows containing text like `Removed`, `superseded`, `shall not implement`, or "not implemented by design" need a human decision. Mark `policy-negative` and ask whether the project wants executable assertions for absence.

Question to settle before coding: should a spec that says "Phase 2 shall not implement X" live as a disabled TODO, an active negative test, or a non-behavioral doc/type `@spec`? Treating it as `unimplemented` is semantically wrong.

## Task 3: Audit By Domain Batches

**Files:**
- Modify: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`

Complete the audit in these batches. Keep each batch small enough that the evidence remains reviewable.

- [ ] **Step 1: Core model and sidebar**

Audit:

```text
Tests/GrafttyTests/Specs/LayoutTodo.swift
Tests/GrafttyTests/Specs/StateTodo.swift
Tests/GrafttyTests/Specs/PersistTodo.swift
```

Primary source/test areas:

```text
Sources/GrafttyKit/Model
Sources/Graftty/Views
Tests/GrafttyKitTests/Model
Tests/GrafttyTests/Views
```

- [ ] **Step 2: Git, PR, divergence, and PWD**

Audit:

```text
Tests/GrafttyTests/Specs/GitTodo.swift
Tests/GrafttyTests/Specs/PrTodo.swift
Tests/GrafttyTests/Specs/DivergeTodo.swift
Tests/GrafttyTests/Specs/PwdTodo.swift
```

Primary source/test areas:

```text
Sources/GrafttyKit/Git
Sources/GrafttyKit/Hosting
Sources/GrafttyKit/PRStatus
Sources/GrafttyKit/Stats
Sources/Graftty/Views
Tests/GrafttyKitTests/Git
Tests/GrafttyKitTests/Hosting
Tests/GrafttyKitTests/PRStatus
Tests/GrafttyKitTests/Stats
```

- [ ] **Step 3: Terminal, zmx, keyboard, mouse, notifications**

Audit:

```text
Tests/GrafttyTests/Specs/TermTodo.swift
Tests/GrafttyTests/Specs/ZmxTodo.swift
Tests/GrafttyTests/Specs/KeyTodo.swift
Tests/GrafttyTests/Specs/KbdTodo.swift
Tests/GrafttyTests/Specs/MouseTodo.swift
Tests/GrafttyTests/Specs/NotifTodo.swift
Tests/GrafttyTests/Specs/BellTodo.swift
```

Primary source/test areas:

```text
Sources/Graftty/Terminal
Sources/GrafttyKit/Zmx
Sources/GrafttyKit/Notification
Tests/GrafttyKitTests/Notification
Tests/GrafttyKitTests/Terminal
Tests/GrafttyKitTests/Zmx
```

- [ ] **Step 4: Web and iOS**

Audit:

```text
Tests/GrafttyTests/Specs/WebTodo.swift
Tests/GrafttyTests/Specs/IosTodo.swift
```

Primary source/test areas:

```text
Sources/GrafttyKit/Web
Sources/GrafttyMobileKit
web-client/src
Tests/GrafttyKitTests/Web
Tests/GrafttyMobileKitTests
```

- [ ] **Step 5: Channels and teams**

Audit:

```text
Tests/GrafttyTests/Specs/ChanTodo.swift
Tests/GrafttyTests/Specs/TeamTodo.swift
```

Primary source/test areas:

```text
Sources/GrafttyKit/Channels
Sources/GrafttyKit/Teams
Sources/Graftty/Channels
Tests/GrafttyKitTests/Channels
Tests/GrafttyKitTests/Teams
```

- [ ] **Step 6: Config, distribution, updates, and technical constraints**

Audit:

```text
Tests/GrafttyTests/Specs/ConfigTodo.swift
Tests/GrafttyTests/Specs/DistTodo.swift
Tests/GrafttyTests/Specs/UpdateTodo.swift
Tests/GrafttyTests/Specs/TechTodo.swift
```

Primary source/test areas:

```text
Sources/GrafttyKit/GhosttyConfigLocator.swift
Sources/GrafttyKit/Updater
Sources/AppcastUpdater
scripts
.github/workflows
docs/release
Tests/GrafttyKitTests
Tests/AppcastUpdaterTests
```

## Task 4: Turn The Audit Into Work Queues

**Files:**
- Modify: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`
- Create later, not in this plan: one plan per implementation/test batch.

- [ ] **Step 1: Recompute summary counts**

After all rows are classified, update the `## Summary` table counts.

- [ ] **Step 2: Produce the implemented-untested queue**

Add:

```markdown
## Implemented But Untested Queue

| Priority | Spec IDs | Proposed test file | Why this batch belongs together |
| --- | --- | --- | --- |
```

Group by existing test target and helper availability. Prefer small batches that can be promoted with focused tests and no production changes.

- [ ] **Step 3: Produce the unimplemented queue**

Add:

```markdown
## Unimplemented Queue

| Priority | Spec IDs | Required implementation area | Why this is separate from test-only work |
| --- | --- | --- | --- |
```

Do not combine unrelated subsystems. A missing web feature and a missing terminal focus feature should become separate future plans.

- [ ] **Step 4: Produce the partial and policy-negative queues**

Add:

```markdown
## Partial / Policy Decisions

| Spec IDs | Decision needed | Recommended resolution |
| --- | --- | --- |
```

Poke holes in each row: if a spec is too broad to test cleanly, split it before promoting it.

## Task 5: Verify The Audit Itself

**Files:**
- Read: `docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md`

- [ ] **Step 1: Confirm every TODO spec appears exactly once in the audit ledger**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import re
todo = set()
for path in Path("Tests/GrafttyTests/Specs").glob("*Todo.swift"):
    todo.update(re.findall(r"@spec\s+([A-Z]+-[0-9]+(?:\.[0-9]+)?)", path.read_text()))
audit = set(re.findall(r"\|\s*`([A-Z]+-[0-9]+(?:\.[0-9]+)?)`\s*\|", Path("docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md").read_text()))
missing = sorted(todo - audit)
extra = sorted(audit - todo)
print(f"todo={len(todo)} audit={len(audit)} missing={len(missing)} extra={len(extra)}")
if missing:
    print("missing:", ", ".join(missing))
if extra:
    print("extra:", ", ".join(extra))
raise SystemExit(1 if missing or extra else 0)
PY
```

Expected: `todo=473 audit=473 missing=0 extra=0`.

- [ ] **Step 2: Run spec generator check**

Run:

```bash
scripts/generate-specs.py --check
```

Expected: PASS. The audit should not mutate spec annotations.

- [ ] **Step 3: Commit the completed audit**

```bash
git add docs/superpowers/spec-audits/2026-04-30-todo-spec-implementation-audit.md
git commit -m "docs(specs): classify todo spec implementation status"
```

## Acceptance Criteria

- Every disabled spec in `Tests/GrafttyTests/Specs/*Todo.swift` is represented exactly once in the audit ledger.
- Every row has one of the five allowed statuses.
- Every `implemented-untested` row cites exact implementation evidence and names the future active test file.
- Every `unimplemented` row cites the absence or mismatch that supports the classification.
- `partial` and `policy-negative` rows ask an explicit decision question rather than hiding ambiguity.
- No production code or active tests are changed during this audit.

## Follow-Up Plans After This Audit

After the ledger is complete, write separate implementation plans:

1. Test-only promotion plan for `implemented-untested` specs, grouped by subsystem.
2. Implementation plans for `unimplemented` specs, one subsystem at a time.
3. Spec-cleanup plan for `policy-negative` or `partial` rows that need splitting, deletion, or conversion to active negative tests.

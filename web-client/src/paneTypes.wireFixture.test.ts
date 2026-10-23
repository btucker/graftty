import { describe, it, expect } from 'vitest';
import releasedRows from '../../Tests/GrafttyProtocolTests/Fixtures/worktree-panes-v1.json';
import enumCaseRows from '../../Tests/GrafttyProtocolTests/Fixtures/worktree-panes-enum-cases.json';
import {
  parseWorktreePanes, type PaneLeaf, type PaneSplit, type PRBadge, type WorktreePanes, type WorktreeWireStats,
} from './paneTypes';

// Two host encodings of `[WorktreePanes]`, both pinned by Swift tests to the
// current encoder:
// - worktree-panes-v1.json (WorktreePanesWireFixtureTests): every top-level
//   CodingKey and every optional part populated.
// - worktree-panes-enum-cases.json (WorktreePanesEnumCasesFixtureTests): every
//   raw value of every enum mirrored here; a new Swift case cannot compile
//   until it is in that file.
// Reading both ties the hand-written TypeScript mirror to the same bytes.
const FIXTURES: Record<string, unknown[]> = {
  'worktree-panes-v1': releasedRows,
  'worktree-panes-enum-cases': enumCaseRows,
};

// The fields the mirror must produce for each shape. Pinned separately from
// what the parser returns, so a parser that stops returning a field fails.
const MIRRORED_KEYS = {
  row: ['path', 'displayName', 'repoDisplayName', 'displayBranch', 'state', 'isMainCheckout',
    'prBadge', 'stats', 'attentionText', 'layout'] satisfies (keyof WorktreePanes)[],
  prBadge: ['number', 'state', 'checks', 'mergeable', 'url'] satisfies (keyof PRBadge)[],
  stats: ['ahead', 'behind', 'hasUncommittedChanges', 'baseRef'] satisfies (keyof WorktreeWireStats)[],
  split: ['kind', 'direction', 'ratio', 'left', 'right'] satisfies (keyof PaneSplit)[],
  leaf: ['kind', 'sessionName', 'title', 'attentionText', 'isBusy', 'attentionSource'] satisfies (keyof PaneLeaf)[],
};
type Shape = keyof typeof MIRRORED_KEYS;

// The only flag the host omits when false (`if isBusy { encode(true, ...) }`).
const OMITTED_WHEN_FALSE = new Set(['isBusy']);

function shapeOf(key: string, value: object): Shape {
  return ('kind' in value ? String(value.kind) : key) as Shape;
}

// Every value the parser produced must equal the wire value at the same path.
// The parsers coerce defensively (unknown enums, missing strings, missing
// booleans), so a retyped field or an enum value the mirror rejects surfaces
// as a default or null that this walk rejects. Null passes only where the wire
// has null or nothing, and false only for a flag the host omits when false.
// A renamed field leaves the old key absent from every wire object, so
// `onWire` records, per `<shape>.<key>`, whether a fixture ever carried a
// value for that mirrored field.
function expectSameAsWire(
  parsed: object, wire: unknown, path: string, shape: Shape, onWire: Map<string, boolean>,
): void {
  expect(wire, path).toBeTypeOf('object');
  expect(wire, path).not.toBeNull();
  expect(Object.keys(parsed).sort(), `${path} keys`).toEqual([...MIRRORED_KEYS[shape]].sort());
  const w = wire as Record<string, unknown>;
  for (const [key, value] of Object.entries(parsed)) {
    const at = `${path}.${key}`;
    const field = `${shape}.${key}`;
    onWire.set(field, onWire.get(field) === true || w[key] != null);
    if (value === null) {
      expect(w[key] ?? null, at).toBeNull();
    } else if (value === false && w[key] === undefined && OMITTED_WHEN_FALSE.has(key)) {
      // Omitted by the host; the parser's false is the encoded value.
    } else if (typeof value === 'object') {
      expectSameAsWire(value, w[key], at, shapeOf(key, value), onWire);
    } else {
      expect(value, at).toBe(w[key]);
    }
  }
}

function walk(name: string, onWire: Map<string, boolean>): void {
  const fixture = FIXTURES[name];
  parseWorktreePanes(fixture).forEach((row, i) => expectSameAsWire(row, fixture[i], `${name}[${i}]`, 'row', onWire));
}

describe('parseWorktreePanes against the host wire fixtures', () => {
  for (const [name, fixture] of Object.entries(FIXTURES)) {
    it(`keeps every row of ${name}`, () => {
      expect(parseWorktreePanes(fixture)).toHaveLength(fixture.length);
    });

    it(`reads every mirrored field of ${name} exactly as the host encoded it`, () => {
      walk(name, new Map());
    });
  }

  it('finds a wire value for every mirrored field of every shape', () => {
    const onWire = new Map<string, boolean>();
    for (const name of Object.keys(FIXTURES)) walk(name, onWire);
    expect([...onWire].filter(([, seen]) => !seen).map(([field]) => field)).toEqual([]);
    const expected = Object.entries(MIRRORED_KEYS).flatMap(([shape, keys]) => keys.map((key) => `${shape}.${key}`));
    expect([...onWire.keys()].sort()).toEqual(expected.sort());
  });
});

import { describe, it, expect } from 'vitest';
import { flexBasisForRatio, flexDirectionFor, leafCount } from './splitGeometry';
import type { PaneLayoutNode } from '../paneTypes';

describe('flexBasisForRatio', () => {
  it('splits proportionally', () => {
    expect(flexBasisForRatio(0.6)).toEqual({ left: 0.6, right: 0.4 });
  });
  it('clamps degenerate ratios so no pane collapses to zero', () => {
    expect(flexBasisForRatio(0)).toEqual({ left: 0.05, right: 0.95 });
    expect(flexBasisForRatio(1)).toEqual({ left: 0.95, right: 0.05 });
  });
});

describe('flexDirectionFor', () => {
  it('maps horizontal splits to a row (side-by-side)', () => {
    expect(flexDirectionFor('horizontal')).toBe('row');
    expect(flexDirectionFor('vertical')).toBe('column');
  });
});

describe('leafCount', () => {
  it('counts leaves in the tree', () => {
    const tree: PaneLayoutNode = {
      kind: 'split', direction: 'horizontal', ratio: 0.5,
      left: { kind: 'leaf', sessionName: 'a', title: '', attentionText: null, isBusy: false, attentionSource: null },
      right: { kind: 'leaf', sessionName: 'b', title: '', attentionText: null, isBusy: false, attentionSource: null },
    };
    expect(leafCount(tree)).toBe(2);
    expect(leafCount(null)).toBe(0);
  });
});

import { describe, it, expect } from 'vitest';
import { previewFontSize } from './paneSizing';

describe('previewFontSize', () => {
  it('sizes the font so ~targetCols columns fit the tile width', () => {
    // 300px / (80 * 0.6) = 6.25 → within [6,14]
    expect(previewFontSize({ tileWidth: 300, targetCols: 80 })).toBeCloseTo(6.25, 2);
  });
  it('clamps to the 14px ceiling for wide tiles', () => {
    expect(previewFontSize({ tileWidth: 5000, targetCols: 80 })).toBe(14);
  });
  it('returns the 6px floor for degenerate input', () => {
    expect(previewFontSize({ tileWidth: 0, targetCols: 80 })).toBe(6);
    expect(previewFontSize({ tileWidth: NaN, targetCols: 80 })).toBe(6);
    expect(previewFontSize({ tileWidth: 300, targetCols: NaN })).toBe(6);
    expect(previewFontSize({ tileWidth: 300, targetCols: 80, cellWidthRatio: 0 })).toBe(6);
  });
});

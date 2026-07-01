export function previewFontSize(opts: { tileWidth: number; targetCols: number; cellWidthRatio?: number }): number {
  const { tileWidth, targetCols, cellWidthRatio = 0.6 } = opts;
  if (!Number.isFinite(tileWidth) || tileWidth <= 0 || targetCols <= 0) return 6;
  const raw = tileWidth / (targetCols * cellWidthRatio);
  return Math.min(14, Math.max(6, raw));
}

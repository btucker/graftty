import type { PaneLayoutNode } from '../paneTypes';

const MIN_RATIO = 0.05;
const MAX_RATIO = 0.95;

export function flexBasisForRatio(ratio: number): { left: number; right: number } {
  const clamped = Math.min(MAX_RATIO, Math.max(MIN_RATIO, ratio));
  const right = Math.round((1 - clamped) * 1000000) / 1000000;
  return { left: clamped, right };
}

export function flexDirectionFor(direction: 'horizontal' | 'vertical'): 'row' | 'column' {
  return direction === 'horizontal' ? 'row' : 'column';
}

export function leafCount(node: PaneLayoutNode | null): number {
  if (!node) return 0;
  if (node.kind === 'leaf') return 1;
  return leafCount(node.left) + leafCount(node.right);
}

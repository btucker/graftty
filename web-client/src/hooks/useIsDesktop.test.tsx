import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useIsDesktop, DESKTOP_MIN_WIDTH } from './useIsDesktop';

function installMatchMedia(initialMatches: boolean) {
  let listener: ((e: MediaQueryListEvent) => void) | null = null;
  const mql = {
    matches: initialMatches,
    media: `(min-width: ${DESKTOP_MIN_WIDTH}px)`,
    addEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => { listener = cb; },
    removeEventListener: () => { listener = null; },
  };
  vi.stubGlobal('matchMedia', () => mql);
  return {
    emit(matches: boolean) {
      mql.matches = matches;
      listener?.({ matches } as MediaQueryListEvent);
    },
  };
}

describe('useIsDesktop', () => {
  beforeEach(() => vi.unstubAllGlobals());

  it('reflects the initial match', () => {
    installMatchMedia(true);
    const { result } = renderHook(() => useIsDesktop());
    expect(result.current).toBe(true);
  });

  it('updates when the media query changes', () => {
    const mm = installMatchMedia(false);
    const { result } = renderHook(() => useIsDesktop());
    expect(result.current).toBe(false);
    act(() => mm.emit(true));
    expect(result.current).toBe(true);
  });
});

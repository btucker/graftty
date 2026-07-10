import { useEffect, useState } from 'react';

export const DESKTOP_MIN_WIDTH = 900;

export function useIsDesktop(): boolean {
  const query = `(min-width: ${DESKTOP_MIN_WIDTH}px)`;
  const [isDesktop, setIsDesktop] = useState<boolean>(() =>
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia(query).matches
      : false,
  );

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mql = window.matchMedia(query);
    const onChange = (e: MediaQueryListEvent) => setIsDesktop(e.matches);
    setIsDesktop(mql.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, [query]);

  return isDesktop;
}

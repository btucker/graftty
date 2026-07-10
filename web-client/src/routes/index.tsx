import { useEffect } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { WorktreeListPage } from '../layout/WorktreeListPage';

export function IndexPage() {
  const navigate = useNavigate();

  // Legacy `?session=<name>` redirect — kept for any old Copy-URL output
  // that users might have bookmarked.
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const session = params.get('session');
    if (session) {
      void navigate({ to: '/session/$name', params: { name: session }, replace: true });
    }
  }, [navigate]);

  return <WorktreeListPage />;
}

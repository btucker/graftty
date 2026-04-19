import { useEffect } from 'react';
import { useNavigate } from '@tanstack/react-router';

export function IndexPage() {
  const navigate = useNavigate();
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const session = params.get('session');
    if (session) {
      void navigate({ to: '/session/$name', params: { name: session }, replace: true });
    }
  }, [navigate]);

  return <div id="status">no session selected</div>;
}

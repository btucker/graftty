import { useParams } from '@tanstack/react-router';
import { TerminalPane } from '../components/TerminalPane';

export function SessionPage() {
  const { name } = useParams({ from: '/session/$name' });
  return <TerminalPane sessionName={name} />;
}

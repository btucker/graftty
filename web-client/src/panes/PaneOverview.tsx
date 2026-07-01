import { useEffect } from 'react';
import { useNavigate } from '@tanstack/react-router';
import { SplitLayout } from './SplitLayout';
import { PanePreview } from './PanePreview';
import type { PaneLayoutNode } from '../paneTypes';

export interface PaneOverviewProps { layout: PaneLayoutNode | null }

export function PaneOverview({ layout }: PaneOverviewProps) {
  const navigate = useNavigate();
  const soloSession = layout && layout.kind === 'leaf' ? layout.sessionName : null;

  useEffect(() => {
    if (soloSession) {
      void navigate({ to: '/session/$name', params: { name: soloSession }, replace: true });
    }
  }, [soloSession, navigate]);

  if (!layout) return <div className="pane-overview-empty">no panes running</div>;
  if (soloSession) return null;
  return (
    <div className="pane-overview">
      <SplitLayout node={layout} renderLeaf={(leaf) => <PanePreview leaf={leaf} />} />
    </div>
  );
}

// web-client/src/panes/SplitLayout.tsx
import type { ReactNode } from 'react';
import type { PaneLayoutNode, PaneLeaf } from '../paneTypes';
import { flexBasisForRatio, flexDirectionFor } from './splitGeometry';

export interface SplitLayoutProps {
  node: PaneLayoutNode;
  renderLeaf: (leaf: PaneLeaf) => ReactNode;
}

export function SplitLayout({ node, renderLeaf }: SplitLayoutProps) {
  if (node.kind === 'leaf') {
    return (
      <div className="pane-slot" data-testid="pane-slot" data-session={node.sessionName}
           style={{ width: '100%', height: '100%', position: 'relative' }}>
        {renderLeaf(node)}
      </div>
    );
  }
  const basis = flexBasisForRatio(node.ratio);
  const direction = flexDirectionFor(node.direction);
  return (
    <div className="split-container" data-testid="split-container"
         style={{ display: 'flex', flexDirection: direction, width: '100%', height: '100%' }}>
      <div className="split-child" data-testid="split-child"
           style={{ flexGrow: basis.left, flexBasis: 0, minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
        <SplitLayout node={node.left} renderLeaf={renderLeaf} />
      </div>
      <div className="split-divider" data-testid="split-divider" data-direction={node.direction} />
      <div className="split-child" data-testid="split-child"
           style={{ flexGrow: basis.right, flexBasis: 0, minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
        <SplitLayout node={node.right} renderLeaf={renderLeaf} />
      </div>
    </div>
  );
}

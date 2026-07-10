import { useNavigate } from '@tanstack/react-router';
import { TerminalPane } from '../components/TerminalPane';
import { displayTitle, type PaneLeaf } from '../paneTypes';

export interface PanePreviewProps { leaf: PaneLeaf }

export function PanePreview({ leaf }: PanePreviewProps) {
  const navigate = useNavigate();
  return (
    <button
      type="button"
      className="pane-preview"
      onClick={() => void navigate({ to: '/session/$name', params: { name: leaf.sessionName } })}
    >
      <div className="pane-preview-terminal">
        <TerminalPane sessionName={leaf.sessionName} role="preview" fit="container" autoFocus={false} />
      </div>
      <div className="pane-preview-title">{displayTitle(leaf)}</div>
    </button>
  );
}

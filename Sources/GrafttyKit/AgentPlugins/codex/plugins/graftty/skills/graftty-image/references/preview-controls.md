# Preview controls

On macOS, the native tray slides down from the terminal area's top without moving the terminal grid or stealing keyboard focus. Background requests remain with their originating pane; each pane's new request replaces its previous image.

- Fit resets the view. Zoom enlarges it; scroll pans.
- Drag the header to move, the bottom edge to change height, or the lower-right grip to resize both dimensions.
- Close dismisses the tray. Escape works only while the preview owns focus.
- Open… opens the original file in Preview.app. Missing or moved files produce a visible tray error.

The Mac tray shows only the first frame or page and bounds decoded resolution. Mobile receives original bytes for native Quick Look with zoom and sharing, accessed through the focused owning pane's Images control. Unsupported leaders or unrecognized Mobile recipients return an error instead of displaying on the host Mac.

Legacy `--width` and `--pad` flags are accepted and ignored. Previews are temporary; request them again when needed.

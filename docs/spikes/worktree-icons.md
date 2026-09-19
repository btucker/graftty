# Worktree SVG atlas

The sidebar now uses one contiguous SVG map per project. Each worktree owns a district with a stable color, a terrain pattern, and a task-related landmark. District borders meet along shared curves, and one route connects the header, every district, folder sections, and the repeating footer. Landmarks remain within the first 80 points and the minimum 220-point sidebar width. Additional pane rows extend the terrain and route without stretching the landmark.

## Meaning and appearance

This iteration uses a local cartographic vocabulary, not an image-generation service. Recent user task context takes priority over the worktree name. Notifications map to beacons and ripples; search to observatories and survey rings; scrolling to canals; authentication to gates; storage to archives; connections to bridges; performance to windmills; deployment to harbors; design to gardens; and repairs to workshops. Unknown tasks receive a stable fallback. These are keyword-based associations, so nuanced or non-English tasks can still need a better interpretation in a future iteration.

The districts share terrain, road materials, building outlines, and an accent sampled from the project avatar when available. Worktree colors are allocated separately; regeneration avoids occupied colors while unused choices remain. More districts than the eleven-color palette necessarily reuse some colors, with patterns and landmarks providing other cues.

Settings → General → Worktree backgrounds enables the atlas and selects Atlas, Bold, or Linework. Existing preference values remain compatible. The project menu's Map Style controls print, ink, contour, mosaic, collage, and other vector treatments. Ghostty's background sets the map ground and its foreground sets the landmark ink. Both colors participate in the map cache key. Terminal backgrounds continue to use gradients sampled from the active district.

## Reordering, regeneration, and storage

The generated SVG contains a bounded metadata block of district descriptors: motif, palette index, and variation. It contains neither raw task prompts nor user-supplied SVG markup. The generator emits only local vector geometry and colors, without embedded raster images, scripts, remote resources, or model-written markup.

Reordering reuses district descriptors and rebuilds the full SVG and shared route locally. Regenerate Background Image refreshes the selected worktree's context and varies only that district. Cached descriptors for hidden worktrees survive reordering and reopening. Removing a worktree removes its descriptor on the next composition.

Each map cache in `~/Library/Caches/Graftty/WorktreeIcons/maps-v1` stores the SVG source alongside its PNG display cache and saves a matching `.svg` file for inspection. Native AppKit decodes the SVG, and the sidebar uses raster previews at the existing fixed map scale. The source remains editable vector artwork; the terminal displays a color gradient. SVG previews bypass photographic detail suppression so connecting routes remain visible through tall pane lists.

The cache revision replaces older image maps once. Existing complete artwork remains visible until the SVG is ready. Missing per-project-medium or foreground-aware caches can display legacy artwork during migration. Disabling artwork cancels generation. Losing focus lets a current map finish and pauses subsequent projects.

## Validation

Tests cover task precedence, valid opaque SVG decoding, source metadata, row boundaries, descriptor preservation across reorder/regeneration/relaunch, distinct colors for similar tasks, all eight project style treatments, foreground-only theme changes, and route visibility through tall rows in a 220-point sidebar. Raw prompts never enter the generated SVG.

The earlier raster map and simple SVG approval studies are superseded by this implementation. Preview artifacts under `output/svg-atlas/` show the current generator with sample Graftty worktrees.

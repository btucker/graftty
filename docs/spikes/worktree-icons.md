# Worktree SVG atlas

The sidebar now uses one contiguous SVG map per project. Each worktree owns a district with a stable color territory and a filled task-related landmark. District borders meet along shared curves, and one route connects the header, every district, folder sections, and the bottom extension. Landmarks sit below a clear 32-point title band, within the first 80 points and the minimum 220-point sidebar width. Additional pane rows extend the terrain and route without stretching the landmark.

## Meaning and appearance

This iteration uses a local vocabulary of 33 direct task illustrations. Recent user task context takes priority over the worktree name. Review tasks show code changes and checks; notifications show messages or approval requests; scrolling shows terminal history; storage shows databases, partitions, or locks; remote tasks show linked computers; artwork tasks show editable images or alternative designs. Each family has three variants. Allocation avoids occupied variants within the family, including hidden worktrees, until all three are in use. Unknown tasks receive a stable fallback. Selection uses keyword rules, so nuanced or non-English tasks can still need a better interpretation in a future iteration.

The districts meet along shared organic borders. A faint route and an accent sampled from the project avatar connect them. Repeating terrain patterns and generic landmark plinths are removed; project media affect the landmark’s fill and stroke instead. Worktree colors are allocated separately; regeneration avoids occupied colors while unused choices remain. More districts than the eleven-color palette necessarily reuse some colors, with landmarks providing other cues. When both color and silhouette choices are occupied, regeneration makes a bounded shade change while retaining the hue and shape.

Settings → General → Worktree backgrounds enables the atlas and selects Atlas, Bold, or Linework. Existing preference values remain compatible. The project menu's Map Style controls print, ink, contour, mosaic, collage, and other vector treatments. Ghostty's background sets the map ground and its foreground sets the landmark ink. Both colors participate in the map cache key. Worktree names use the district's persistent hue, with quieter matching pane labels. Quiet territory fills and uniform row shading leave room for colored text. Text contrast adjusts to the rendered terrain, theme, and selection. Git statistics and attention indicators retain their semantic colors.

Selecting a worktree carries its color across the native titlebar, project rail, worktree header, and breadcrumb. Breadcrumb and neutral PR text adjust to the tinted background. One gradient continues behind all terminal panes and fades into the configured Ghostty background. Disabling artwork or selecting a remote worktree restores normal chrome. SVG display previews carry the exact descriptor color; legacy raster artwork still uses sampled colors.

## Reordering, regeneration, and storage

The generated SVG contains a bounded metadata block of district descriptors: motif, palette index, variation seed, and silhouette variant. It contains neither raw task prompts nor user-supplied SVG markup. The generator emits only local vector geometry and colors, without embedded raster images, scripts, remote resources, or model-written markup.

Reordering reuses district descriptors and rebuilds the full SVG and shared route locally. Later prompts preserve an established place. Regenerate Background Image explicitly refreshes the selected worktree's context and varies only that district. Cached descriptors for hidden worktrees survive reordering and reopening. Removing a worktree removes its descriptor on the next composition.

Each map cache in `~/Library/Caches/Graftty/WorktreeIcons/maps-v1` stores the SVG source alongside its PNG display cache and saves a matching `.svg` file for inspection. Native AppKit decodes the SVG, and the sidebar uses raster previews at the existing fixed map scale. The source remains editable vector artwork; the terminal displays a color gradient. SVG previews bypass photographic detail suppression so connecting routes remain visible through tall pane lists.

The cache revision upgrades older maps once. Earlier SVG districts keep their colors, seeds, and variant assignments through presentation upgrades. This revision replaces the architectural drawings with direct task illustrations. Legacy descriptors without a silhouette receive one on upgrade. The header and bottom extension use straight routes so resizing or repeating the extension introduces no recurring bends or decorative tiles. Existing complete artwork remains visible until the SVG is ready. Missing per-project-medium or foreground-aware caches can display legacy artwork during migration. Disabling artwork cancels generation. Losing focus lets a current map finish and pauses subsequent projects.

## Validation

Tests cover task precedence, valid opaque SVG decoding, source metadata, row boundaries, descriptor preservation across reorder/regeneration/relaunch, distinct colors for similar tasks, a clear title band and texture-free extended terrain, all eight project style treatments, foreground-only theme changes, and route visibility through tall rows in a 220-point sidebar. Header tests cover selection changes, contrast, and panels wider than the fixed SVG canvas. Cache restoration checks that previews retain their descriptor colors. Raw prompts never enter the generated SVG.

The earlier raster map and simple SVG approval studies are superseded by this implementation. Preview artifacts under `output/svg-atlas/` show the current generator with sample Graftty worktrees.

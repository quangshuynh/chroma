# Architecture

## Interval 1 audit and integration

Interval 2 starts at `dbbaf28`, the reviewed merge of Interval 1 (`93d0651`) into `main`. The original content model held one `RasterSurface`; its `composite` was that raster's `CGImage`. `ChromaDocument` owned lock-protected content, file identity, dirty state, safe PNG writes, and windows. Each editor window captured a fixed content value. `EditorState` and `CanvasNSView` held navigation only. ImageIO decoded ordinary files into normalized immutable pixels and exported that one raster.

The single-raster assumptions were isolated to `ImageDocument`, the codec output path, the fixed window/canvas snapshot, and PNG-only document saving. Those boundaries changed; the native document shell, immutable pixel storage, image import normalization, viewport math, checkerboard, and new-image form remain in use.

## Ownership and invariants

`PixelSize` validates dimensions. `RasterSurface` owns an immutable Core Graphics snapshot in 8-bit premultiplied RGBA, explicitly ordered in sRGB. Copying a surface retains storage; the public API never exposes mutable pixels. Normalization remains at image-import boundaries. The native codec can create a surface directly from validated canonical bytes without a color or alpha conversion.

`ImageDocument` owns a stable document UUID, authoritative canvas dimensions, and an ordered collection of `RasterLayer` values. The order is **bottom-to-top**. Every layer has a stable UUID, name, canvas-sized raster, visibility, and finite opacity in `0...1`. Properties can be extended later without introducing unused blend/transform/mask fields now.

Layers cannot be empty, have duplicate IDs, or have different dimensions. There are at most 128 layers and 128 million total layer pixels. These limits bound a current stack, not undo history or all process allocations. Names are trimmed, must have 1–255 characters, and cannot contain control characters. Selection always references an existing layer.

The active-layer UUID is held alongside the content for invariant enforcement and undo selection restoration, but is **transient session state**: it is omitted from the format and changing it does not mark the document edited. Reopening selects the top layer. `NSDocument` owns file identity and dirty state. A UUID-based render revision is also transient.

## Mutation and undo

Views receive `EditorPresentation` snapshots and invoke document commands. They never mutate the layer array or pixels. `ImageDocument.apply(LayerEdit)` validates an edit against a local value and commits only on success. No-ops return false. Errors preserve the complete previous state.

- Add inserts a transparent layer above the selected layer and selects it.
- Duplicate inserts a new identity above its source, preserving raster/visibility/opacity. Immutable raster storage is safely shared; future pixel edits must replace it, not mutate a retained image.
- Delete selects the layer below when deleting the active layer; deleting the bottom layer selects the next one. Deleting an unselected layer preserves selection. The last layer cannot be deleted.
- Move takes a final, valid bottom-to-top index and preserves identity.
- Rename leaves the render revision unchanged. Visibility, opacity, order, and structural edits invalidate rendering.

`ChromaDocument.perform` prepares the new model and composite before replacing state. It registers the inverse through the native `UndoManager`, with human-readable action names. Undo/redo restore metadata values and references to immutable rasters; property edits never store full-resolution composite snapshots or copy all layer pixels. Structural edits retain the raster buffers needed to undo deletion, merge, and flatten. This deliberately small value-based history can later accept pixel replacements without coupling tools to the inspector.

`NSDocument` observes its undo manager and handles dirty-state traversal. Tests exercise editing, undo back to a saved state, redo, failed edits, and no-ops. New documents start dirty; imported/native opened files start clean. Zoom, pan, inspector visibility, selection, and export are document-neutral.

The inspector retains only draft name/opacity values. Explicit selection and layer actions commit a pending valid name before the action; an undo-driven snapshot refresh only replaces draft text and cannot create a rename. Opacity drags apply on release, producing one document edit; keyboard/accessibility adjustments commit individual steps. The compositor is not run for each slider movement.

## Compositing and invalidation

`LayerCompositor` is independent of AppKit and SwiftUI. It visits visible nonzero-opacity layers bottom-to-top using normal source-over in the existing **encoded sRGB** working space (not linear-light blending). All four premultiplied channels use:

`out = round(source * opacity + destination * (1 - sourceAlpha / 255 * opacity))`

Each layer rounds once to the nearest 8-bit value, with ties away from zero. Transparent output has zero RGB. An unchanged single visible layer at opacity 1 returns the original retained surface; importing a flat image does not allocate a second composite buffer. Pixel fixtures specify ordering, partial alpha, opacity, hidden layers, and rounding.

`DocumentStorage` keeps the current immutable model and one composite under its existing narrow lock boundary for concurrent AppKit reads. On mutation, the compositor runs only if the render revision changed. Renaming and selection reuse the composite. Windows receive explicit snapshot updates, and the canvas swaps its retained image without resetting the viewport. SwiftUI body evaluation, zoom, pan, and inspector toggles cannot recomposite the image. Export computes from a captured immutable model off the main actor.

Layer-property/structural operations, undo/redo, and native package encoding remain synchronous. Painting uses a transient affected-region preview cache, described below; the persisted raster and ordinary compositor remain full-image. Measured costs and memory limits are in [painting](painting.md).

## Merge and flatten precision

Flatten Image replaces all layers with their composite, visible at opacity 1, preserves the active UUID, and retains final alpha. Hidden content is discarded but recoverable through undo.

Merge Down currently supports **only the bottom two layers**. It uses their composite as the bottom layer's new raster, preserves that layer's ID/name, sets it visible at opacity 1, and selects it if the removed upper layer was active. Both layers' current visibility/opacity are baked in; hidden source pixels are recoverable through undo.

This restriction is intentional: with an 8-bit source-over accumulator, quantizing a middle sub-stack before compositing it over lower layers can change rounding and therefore pixels. The bottom pair has the same transparent backdrop before and after merging, so the remaining stack renders byte-identically. Arbitrary middle merges are deferred until a precision policy is chosen; the menu disables them and inspector help explains the restriction.

## Native shell and inspector

An AppKit entry point/document controller hosts SwiftUI inside native document windows. The inspector shows the topmost layer first in a native selectable list, eye toggles, names, and opacity values. It provides add, duplicate, delete, rename, opacity, merge/flatten, and bounded Move Up/Down controls. Explicit reorder controls support keyboards/accessibility without introducing drag/drop identity and insertion-index ambiguity in this interval. No drag/drop behavior is claimed.

The Layer menu mirrors structural actions and validates availability. Native Edit menu commands retain Cmd-Z/Cmd-Shift-Z and responder-chain text editing. Disabled states, selected rows, visibility values, opacity, and control labels are exposed through native accessibility. Live accessibility-tree inspection is distinct from VoiceOver verification.

## Files and lifecycle

Ordinary PNG/JPEG/TIFF/HEIC import still uses ImageIO's first/primary image, applies EXIF orientation, and normalizes once. The initial layer is named from the source filename when valid, with `Background` as fallback. Blank transparent/white documents create a single `Background` layer with the existing pixel behavior.

Save/Save As write editable `.chroma` packages using `NSDocument` safe writing. An imported image must choose a native destination; it is never implicitly overwritten with flattened pixels. Saving an existing native project uses its destination. Autosaving in place remains disabled. Read failure does not replace existing content. Native package validation and serialization live in `ChromaCore`; details are in [native format](native-format.md).

PNG/JPEG are exports, independent of native Save. Both receive the visible composite and never UI state. PNG retains alpha; JPEG retains Interval 1's explicit white matte and 92% quality. Export uses a detached task and atomic file replacement after encoding. It does not change document identity, layers, history, or dirty state. A flattened export does not satisfy the pending native save of an edited project.

## Existing viewport and import limits

Zoom is physical display pixels per image pixel. At 100%, a 1000-pixel image spans 500 points on a 2× display. Image origins align to display pixels without stretching odd-sized rasters. Integer/high zoom uses nearest-neighbor interpolation; reduced zoom uses high-quality display interpolation. Fit tracks resizing until explicit navigation, with 24-point margins; pan stays reachable. The checkerboard visits only visible cells and never enters export.

Individual rasters remain limited to 16,384 pixels per side and 32 million pixels, with 256 MB per imported encoded image. Metadata, original profiles/high bit depth, additional pages/frames, and auxiliary images are not preserved. Multiple documents, normalization/encoding intermediates, composites, native byte buffers, and retained undo rasters can exceed the current-layer memory bound. Signing remains local ad-hoc; there is no release signing or notarization.

## Pixel editing boundary

`CanvasNSView` interprets AppKit input and asks `Viewport` for top-left document coordinates. `PixelStroke` in ChromaCore owns tool behavior, interpolation, one copy-on-write working raster, and a maximum-coverage byte per pixel. No SwiftUI or AppKit event enters that engine. `ImageDocument.replaceRaster` is the reusable validated replacement boundary; it retains layer identity, name, visibility, and opacity and changes the render revision. Future pixel tools can use it without changing the canvas or native format.

`ChromaDocument` owns at most one transient pixel gesture (stroke or selected-pixel move). Down captures the active layer ID, document ID, render revision, immutable layer references, and settings. Drag changes only the working raster and preview regions. Up validates the target, stamps the endpoint, builds an immutable raster and prepared composite, and uses the existing native undo boundary once. A no-op creates no history. Undo/redo retain pre/post raster references through document value snapshots, not full composite snapshots or per-event buffers. Unrelated layers keep their original references and metadata.

The document model always has an active layer; an unloaded document safely ignores painting. Hidden and zero-opacity active layers reject painting explicitly. There is no lock scaffold. Selection, any layer mutation, undo/redo, tool/size/color change, Escape, focus loss, window/app deactivation, actual canvas resize, backing-scale change, viewport navigation, save/export interaction, and close cancel unfinished work. Cancellation discards previews and working pixels and never registers history. Document replacement also cancels, and revision/identity validation prevents stale events from retargeting another layer. Unchanged SwiftUI layout calls preserve strokes. All windows receive the committed raster directly as well as observed presentation updates, avoiding a stale representable snapshot.

`EditorState` owns tool, size, foreground/background colors, zoom, and feedback text. These remain session state. Native color values convert to sRGB, clamp to `0...1`, and quantize to straight RGBA8; the core explicitly premultiplies when painting. Eyedropper samples the cached visible composite including layer opacity and visibility, then unpremultiplies for foreground color. Fully transparent samples are transparent black. Quantized low-alpha colors cannot recover lost straight-color precision.

## Stroke rasterization and display

Pencil replaces pixels directly in an integer-aligned square, without antialiasing. For diameter `d`, its origin is `floor(point) - floor(d/2)` and its extent is exactly `d` pixels. Brush uses round coverage `clamp(radius + 0.5 - distanceFromPixelCenter, 0, 1)`, quantized to a byte, then premultiplied source-over against the starting pixel. Eraser scales every premultiplied channel by `1 - coverage`; it ignores the selected color and erases at full strength. Maximum coverage within one gesture prevents opacity from depending on overlapping stamps; subsequent gestures can build up paint or erasure.

Arc-length spacing is 0.5 document pixels for Pencil and `max(0.5, diameter/4)` for round tools. Residual distance carries between events, and mouse-up includes the endpoint. Tiny moves do not generate unbounded stamps. Sizes clamp to 1–512; stamping clips before visiting pixels. Nonfinite input is ignored and extreme off-image input is clamped to a brush-sized apron, bounding work. Paths far outside the canvas follow that clamped path, rather than preserving arbitrary off-canvas geometry.

The inverse viewport transform shares the rounded image origin used for drawing, flips AppKit's bottom-left Y into top-left raster rows, and accounts for pan and the physical-pixel zoom definition. Backing scale affects only the display transform. Cursor footprints use the forward transform; square Pencil and round Brush/Eraser outlines have black/white strokes and never enter pixels, persistence, or export.

Baseline full compositing measured tens to hundreds of milliseconds for four-layer 1k/2k canvases. To avoid this per drag event, changed pixels flag 128-pixel preview patches. Only dirty patches are recomposited across the captured layer stack, using identical channel math and substituting the working active layer. Cached patch images replace the corresponding portion of the base composite; drawing cuts holes in the base so erased alpha reveals checkerboard or lower layers correctly. Patches are transient, bounded by the canvas, and discarded at stroke end, with no persistent tile storage, GPU renderer, or background scheduling. Canvas invalidation remains a coalesced AppKit redraw; expensive pixel recomposition is region-limited.

At commit, the engine refreshes any final endpoint patches, copies the prior composite once, replaces the affected rows, and validates the immutable result. Pixel tests compare this assembled result to a full recomposite. This avoids the measured mouse-up stall. Working raster, coverage, and preview images are released after commit/cancel; native history retains the required full raster versions. See [painting](painting.md) for measurements and limitations.

## Selection and region boundary

`SelectionMask` lives in ChromaCore but is held outside `ImageDocument`, in the main-actor document adapter. Nil means unrestricted editing; an active empty mask means nothing selected. Binary row spans support rectangles, deterministic pixel-center ellipses, inversion, and clipped translation without allocating one byte per canvas pixel. The canvas owns only a drag preview and a cached outline path. Selection commands update overlay/status/accessibility state without replacing document content, changing render revision, recompositing, or registering undo.

`PixelStroke` captures the mask and checks membership at its existing mutation boundary. `RegionEditing` provides copy/delete/crop/paste against immutable inputs. `PixelMove` captures an immutable document plus mask, copies/clears/composites spans into a regional replacement, and calls the existing regional compositor for a display-only preview. Commit validates identity/revision and uses `replaceRaster` followed by the established synchronous main-actor undo boundary. All mutable buffers are independently owned; retained provider-backed images remain immutable.

Paste inserts a new canvas-sized layer above the active one at origin, so there is no uncommitted pasted-content state. Crop reconstructs all raster layers at the same clipped integer bounds, retaining metadata and IDs. Dimension changes clear selection and explicitly update the canvas raster and viewport, including on undo/redo. Other pixel undos retain the current transient selection. `.chroma` version 1 is unchanged. The private native clipboard representation preserves canonical low-alpha bytes, while PNG/TIFF provide bounded interoperability.

Selection paths are drawn after content and never passed to codecs. Movement uses the union of source and destination for regional recomposition and old/new bounds for AppKit invalidation. Large unions and full-stack commit/undo remain synchronous. [Selection documentation](selections.md) specifies geometry, alpha, lifecycle, dirty state, clipboard layout, undo boundaries, performance, and limitations.

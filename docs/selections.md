# Selections and region editing

Choose Rectangle Select or Ellipse Select in the Tool menu and drag on the canvas. Drag in any direction; release to finalize, or press Escape to retain the previous selection. Clicking without an area deselects. The Selection menu provides Select All (⌘A), Deselect (⌘D), Invert Selection (⇧⌘I), and Crop to Selection. A text summary reports the selection's pixel bounds; the canvas exposes the same information to accessibility. Image commands live on the canvas responder, so native text fields retain their editing shortcuts. Focus the canvas to use region commands.

## Geometry and representation

`SelectionMask` is an immutable, binary mask of sorted, disjoint, half-open horizontal spans for each canvas row. It uses O(height + spans) storage for rectangles, ellipses, and their inverses, with no full-resolution byte mask. This representation can later accept irregular regions without changing the mutation interface. There is no feathering or partial selection coverage in this version.

Coordinates are top-left document pixels: X increases right, Y increases down, pixel centers are `(x + 0.5, y + 0.5)`. Drag endpoints floor to integer pixel edges before normalization. A zero-width or zero-height drag has no area. Finite extreme drag coordinates are bounded to ±1 billion before arithmetic. Rectangle membership uses half-open bounds; ellipse membership includes centers on the mathematical ellipse boundary. Rasterization clips to the canvas after evaluating the original shape, including when a drag ends beyond an edge. A row-span outline follows those exact binary pixel edges, so ellipses intentionally look stepped at high zoom.

The editor distinguishes **no selection** (`nil`, all pixels editable) from **an active empty mask** (no pixels editable). Select All creates a full mask; inverting it creates an empty mask. Inverting no selection selects the whole canvas. Inverting twice restores the same mask. An empty mask is reported in text even though it has no visible outline. Selection persists across active-layer changes and is shared by a document's windows.

## Painting and display

`PixelStroke` captures the selection at mouse-down. Its existing stamp mutation boundary skips unselected pixels before applying Pencil replacement, Brush source-over, or Eraser alpha reduction. Interpolation, maximum stroke coverage, brush edge antialiasing, size, and color semantics are unchanged. Brush coverage remains antialiased even though the selection itself is binary. Eyedropper samples the composite independently of selection.

The canvas caches a static black/white dashed path separately from its retained raster. The path uses the same viewport transform as painting, with screen-sized strokes after zoom and pan. No timer or overlay event recomposites document pixels. Selection and movement invalidate their old/new affected bounds. The checkerboard, cursor, and selection path never enter the native codec or image encoder.

## Pixel operations

Copy (⌘C) extracts active-layer pixels inside the mask's bounding rectangle, with transparent pixels outside the mask. No selection copies the entire active layer; an empty mask disables Copy. Hidden layer pixels can be copied, cut, or deleted explicitly. Copy ignores layer opacity and visibility, preserving the underlying raster.

Cut (⌘X) writes the clipboard successfully before deleting. Delete/Forward Delete clears selected premultiplied RGBA channels to zero on the active layer. No selection deletes the entire active layer; an empty mask does nothing. Already-transparent deletion does not create history. Neither operation paints a background color or changes layer metadata.

The native pasteboard publishes PNG and a private `com.chroma.raster-rgba-v1` representation (two little-endian UInt32 dimensions followed by canonical premultiplied RGBA bytes). Chroma-to-Chroma transfer is exact for every low-alpha byte; PNG interoperability can round RGB when converting between straight and premultiplied alpha. External PNG and TIFF inputs use the existing bounded ImageIO decoder. Other representations, vector clipboard objects, and arbitrary file URLs are not supported.

Paste (⌘V) immediately inserts a visible, full-opacity **new raster layer above the active layer**, named Pasted Image, at canvas origin `(0, 0)`. It selects the pasted bounds and the new layer. Existing pixels are never overwritten. Content larger than the canvas is clipped at its right/bottom edges; the canvas does not expand. The new layer is committed in one undo step and may then be moved with Move Selected Pixels. Pasted content has no additional floating state.

Crop to Selection uses the mask's **bounding rectangle**, including for ellipses and inversions. It copies the same integer-aligned rectangle from every layer, preserving IDs, names, visibility, opacity, active layer, and document identity. It does not clear pixels outside an ellipse inside that rectangle. Empty bounds or full-canvas bounds are no-ops. A successful crop clears selection and updates the viewport dimensions; fit mode recalculates fit, while explicit zoom stays fixed with constrained pan. Undo restores the original dimensions and all layer pixels exactly.

## Movement lifecycle and undo

`ChromaDocument` owns either no pixel gesture, a stroke, or a `PixelMove`. The canvas alone owns a selection-drag preview. Move Selected Pixels requires a nonempty selection on a visible, nonzero-opacity layer and a drag starting inside it.

| Event | Result |
| --- | --- |
| Mouse-down | Retain immutable starting document and mask; committed content stays unchanged. |
| Drag | Round displacement to whole document pixels. Preview from the same original snapshot every time. |
| Release | Validate document/layer/revision; commit one raster replacement and one native undo group if bytes changed. Translate and clip selection. |
| Escape or interruption | Discard preview and gesture; original raster and selection remain exact. |
| Tool, size, color, layer, or selection change | Cancel unfinished pixel/selection gestures before applying the new state. |
| Undo/redo or layer edit | Cancel gestures, then restore the normal immutable document snapshot synchronously on the main actor. |
| Navigation, real resize, backing-scale change, focus loss, app/window deactivation | Cancel unfinished gestures. Unchanged layout preserves them. |
| Save/export UI, document replacement, close | Cancel unfinished gestures. Codecs always receive committed content. |

Each preview copies only the bounding union of source and clipped destination. It clears source spans, then source-over composites translated selected pixels from the original raster onto that cleared base. Clearing precedes all destination writes, so overlapping moves do not smear or double-apply alpha. Transparent selected pixels do not erase unselected destination pixels. Source-over uses the same encoded-sRGB, rounded premultiplied math as layer compositing. Off-canvas pixels are discarded on commit and recoverable with Undo. Returning to displacement zero is exact and creates no history; moving entirely transparent content changes only the transient mask.

The preview region is recomposited through the existing layer compositor, with other layers and active-layer opacity respected. Commit creates a full replacement raster and the ordinary committed composite. Cancellation discards references rather than performing an inverse pixel edit.

Selection-only changes are not in image undo history and never dirty the document. Undo/redo of pixel operations preserves the current selection when canvas size is unchanged; dimension changes clear it. Thus undoing a move restores pixels but does not move the outline back. Use Select All or draw another selection as needed. Delete, Cut, Paste, Move, and Crop each use the existing synchronous, main-actor native undo registration; a drag never creates per-event entries. History retains immutable raster versions, not per-event previews or redundant composite snapshots.

`.chroma` remains schema version 1. Selection, preview geometry, and overlays are not serialized. Pixel edits, pasted layers, cropped dimensions, and metadata persist through save/reopen. PNG and JPEG use only the committed composite, including during an unfinished gesture.

## Measured costs and limits

Run `swift run -c release ChromaBench 1000 4` and `swift run -c release ChromaBench 2000 4`. After the painting workload, the harness measures ellipse creation, outline generation, 60 distinct diagonal translations (1–60 pixels), finish, delete, and multi-layer crop. Each fixture has four visible layers at opacity 0.7. Timings are engine CPU work, not end-to-end input latency or frame-rate guarantees.

Measured October 8, 2026 on Apple M1, 16 GiB RAM, macOS 26.6.2, Xcode 27 / Swift 6.4, with the desktop and native UI verification active:

| Canvas / ellipse extent | Mean move event | Worst event | Finish raster | Delete | Crop, all four layers |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1000² / 128² | 2.77 ms | 3.57 ms | 2.27 ms | 2.63 ms | 1.21 ms |
| 1000² / 500² | 26.09 ms | 28.90 ms | 2.76 ms | 2.63 ms | 2.88 ms |
| 2000² / 128² | 4.82 ms | 6.89 ms | 9.17 ms | 12.04 ms | 5.44 ms |
| 2000² / 1000² | 158.48 ms | 671.99 ms | 21.27 ms | 21.14 ms | 27.68 ms |

Geometry took 0.056–0.106 ms and outline generation 0.058–0.155 ms. Across all 60 events, the small region visited 1,525,330 preview pixels, versus 60 million or 240 million for full-canvas recompositing. The larger regions visited 16,903,810 and 63,733,810 pixels. A large outlier occurred in the 2k workload while the desktop was active; no low-latency guarantee is implied. Final full-stack composite time is additional to the reported finish-raster time.

Movement retains the original immutable rasters, one region replacement and one regional composite, plus temporary regional bytes during updates. Full-canvas selection/movement can still approach full-image work and memory. Commit and undo retain full raster versions; crop retains old and new rasters for every layer. Native undo remains unbounded by bytes. Large moves, distant source/destination unions, deep layer stacks, crop, saves, and undo can block the UI. A tiled renderer, asynchronous preview pipeline, and region-delta history remain future work; no Metal or transform framework was added.

No lasso, magic wand, additive/subtractive gestures, feathering, resize/rotation, off-canvas storage, or general selection-transform UI is implemented. Clipboard compatibility and manual hardware coverage are deliberately bounded; see [verification](verification.md).

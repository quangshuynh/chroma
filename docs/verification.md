# Verification

Verified October 8, 2026 on macOS 26.6.2 (25G83), Apple M1 with 16 GiB RAM, Xcode 27.0 (27A266a), and Swift 6.4, targeting macOS 14+. Physical Intel hardware and macOS 14 were not exercised. The starting main commit `4e03dea` includes the painting interval and its actor-isolation / immutable-preview fixes; its [Validate workflow passed](https://github.com/quangshuynh/chroma/actions/runs/37771191504) before feature work began.

## Automated coverage

The suite contains **123 test functions in ten suites, 201 executions including parameterized cases**. Core and AppKit integration suites use small deterministic raster fixtures and exact byte expectations where the format supports them.

| Suite | Functions | Coverage |
| --- | ---: | --- |
| DocumentTests | 6 | Dimensions, blank pixels, viewport/content separation |
| ViewportTests | 8 | Fit, zoom, aligned origins, pan constraints, physical-pixel display sizing |
| ImageCodecTests | 13 | PNG/JPEG/TIFF/HEIC, orientation, alpha, malformed/oversized input, atomic exports |
| LayerTests | 19 | Layer invariants, immutable sharing, exact source-over, invalidation, merge/flatten, export |
| NativeCodecTests | 8 | Exact package/disk round trips, every alpha value, metadata, malformed packages |
| PaintingTests | 22 | Explicit Pencil/Brush/Eraser bytes, interpolation, clipping, targeting, stale gestures, sampling, immutable previews, persistence/export |
| SelectionTests | 14 | Every rectangle drag direction, binary ellipses, clipping without reshaping, inversion, empty/full masks, selection-aware tools, copy/delete, overlap/alpha/negative movement, regional preview equivalence, crop/paste, metadata and codecs |
| NativeDocumentTests | 13 | Native save/open/failure, undo, saved-state traversal, dirty state, cache reuse, window/menu updates, draft rename regression |
| PaintingDocumentTests | 9 | Gesture grouping, exact synchronous undo/redo, no-op/cancel, lifecycle interruption, native save, neutral controls, event adapter, layout/canvas regressions |
| SelectionDocumentTests | 11 | Selection neutrality/cache reuse, delete/cut/paste/move/crop undo and dirty state, clipboard low alpha/external PNG/malformed payloads, movement cancellation, retained snapshots, dimension refresh, saved state, native events, text focus, preview-free exports |

Coordinate tests cover 1×/2× backing scales and 1%, 50%, 100%, 800%, and 3200% zoom with pan. Actual canvas event dispatch tests rectangle/ellipse selection and move cancellation at 50%, 100%, 800%, and 3200%. Existing painting event tests cover painting, sampling, hovering, panning, and Escape. Selection-aware tests cover transparent and partially transparent pixels, oversized brushes, empty masks, exact Pencil replacement, source-over Brush, and channel-wise Eraser reduction.

Move fixtures specify exact overlapping source/destination pixels with partial alpha, negative and completely off-canvas translation, return to zero, an inverted ellipse in two dimensions, unavailable layers, and transparent no-ops. Preview bytes are compared with the final layer/composite, including opacity. Retained source and earlier-preview snapshots are checked for mutation. Document tests repeat synchronous undo/redo and assert visible canvas bytes after each step, covering the earlier actor-isolation and stale-canvas regressions.

Clipboard tests use isolated named pasteboards, preserving every alpha byte in the private format. External PNG fallback and malformed private data are exercised. Crop tests retain all layer identities/metadata, restore dimensions and every raster with Undo, and traverse native saved-state boundaries. Native and PNG/JPEG encoders are invoked during an unfinished move and checked against committed pixels. Lossy JPEG comparisons use explicit tolerances in codec/painting fixtures; native storage remains authoritative for all low-alpha values.

## Interactive checks actually performed

Native computer-use input, accessibility-tree inspection, and screenshots exercised the optimized app in the system dark appearance:

- Created a 128×96 transparent image. Drew a rectangular selection at fit/high zoom and observed aligned dashed pixel bounds and a textual/AX selection description.
- Painted a Brush stroke through rectangle boundaries; the stroke stopped at the selected edges. Copy/Paste created a new Pasted Image layer at `(0, 0)` with transparent surroundings.
- Selected Move Selected Pixels and dragged the copied region. Observed translated pixels/outline and issued native Undo/Redo; automated assertions separately prove each intermediate pixel state.
- Created an elliptical selection across a painted stroke and inverted it. Screenshots showed the stepped ellipse boundary, its hole, and the outer canvas boundary. Cut removed only the ellipse pixels; a separate Undo screenshot showed the full stroke restored, and Redo/Paste recreated the expected separate layer.
- Cropped to pasted selection bounds. Canvas and metadata became 57×38 with both layers retained. Undo returned to 128×96, Redo returned to 57×38, and fit recalculated at each size.
- Exercised Cmd-A, Cmd-D, and Shift-Cmd-I with canvas focus. Inspected native Selection menu availability, tool labels, and disabled brush size for selection/movement.
- Saved a two-layer `.chroma` package through the native dialog, selected all, exported PNG and JPEG through native dialogs, then closed without a save prompt. This is a live check that selection/export did not introduce unsaved content. Reopened the native package and observed both layers, the cropped dimensions, expected content, and no persisted selection.
- Independently decoded those live output files with ChromaCore. The PNG was byte-identical to the saved committed composite; the JPEG matched a fresh encoding of that composite. Neither contained an overlay.
- Resized the window to inspect compact controls. They wrapped into two native rows; this check led to increasing minimum height from 460 to 520 points to keep the Layers list usable alongside the selection summary.

Native automation sometimes required a separate observation after a tool/focus change before the next gesture registered, as in earlier painting verification. Results above count observed final states, not attempted actions. Live clipboard checks were within Chroma; external clipboard compatibility is an automated PNG check, not a claim about every macOS image application.

## Remaining verification boundaries

Actual VoiceOver speech/navigation, light appearance, native color-panel alpha interaction, physical non-Retina/multiple displays, real trackpad/pointer hardware, external-app TIFF clipboard handoff, and maximum-size/deep-stack interactive responsiveness remain unverified. Accessibility-tree labels and automated AX assertions are not VoiceOver verification. Live movement cancellation and exact low-alpha overlap are covered by native event/domain tests rather than a manual mid-drag Escape session. Selection-only/no-op dirty state is asserted programmatically, in addition to the live save/selection/export/close check.

No broad clipboard compatibility, off-canvas pixel retention, selection feathering, lasso, or general transform support is claimed. The outline is static, avoiding decorative timers. Undo retains full raster versions without a byte budget. Large moves, crop, layer operations, undo/redo, and native saves remain synchronous. [Selection measurements](selections.md) and [painting measurements](painting.md) report engine CPU work, memory costs, and observed outliers; they are not frame-rate guarantees. Bundle signing is local ad-hoc, with no Developer ID signing, notarization, tag, or release.

## Reproducible validation

```sh
swift package clean
Scripts/validate.sh
```

The clean validation run passed all 123 functions / 201 executions with no compiler warnings. Validation includes strict recursive swift-format lint, plist validation, the complete test suite, optimized app/benchmark builds, ad-hoc bundle signature verification, and Git whitespace checks. Benchmark outputs and live temporary fixtures are excluded from commits.

Recommended reviewer follow-up: VoiceOver and color-panel interaction, external clipboard apps, physical display/trackpad coordinates, and large-document responsiveness. A focused next interval should address bounded undo memory and large-region preview scheduling before expanding the transformation surface.

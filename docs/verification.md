# Verification

Verified October 7, 2026, on macOS 26.6.2 (25G83), Apple M1 with 16 GiB RAM, Xcode 27.0 (27A266a), and Swift 6.4, targeting macOS 14+. macOS 14, Intel hardware, and remote CI have not been personally exercised.

## Automated coverage

The complete suite contains **96 test functions in eight suites, 154 executions including parameterized cases**. The painting additions comprise 21 core functions (41 executions) and eight AppKit integration functions, alongside the existing 67 functions / 105 executions.

| Suite | Functions | Coverage |
| --- | ---: | --- |
| DocumentTests | 6 | Dimensions, blank pixels, viewport/content separation |
| ViewportTests | 8 | Fit, zoom, aligned origins, pan constraints, physical-pixel display sizing |
| ImageCodecTests | 13 | PNG/JPEG/TIFF/HEIC, EXIF orientation, alpha, malformed/oversized input, atomic exports |
| LayerTests | 19 | Layer invariants/operations, immutable sharing, exact source-over, invalidation, merge/flatten, export |
| NativeCodecTests | 8 | Exact package/disk round trips, all low-alpha values, metadata, invalid/symlink/oversized files |
| PaintingTests | 21 | Color conversion, explicit Pencil/Brush/Eraser bytes, interpolation, clipping, size bounds, targeting, stale gestures, sampling, preview/full-composite equivalence, persistence/export |
| NativeDocumentTests | 13 | Native save/open/failure, undo/redo, saved-state traversal, dirty state, cache reuse, window/menu updates, draft rename regression |
| PaintingDocumentTests | 8 | One undo per gesture, exact redo, no-op/cancel cleanliness, selection/deletion/undo interruption, painted save/reopen, neutral editor state, AppKit event adapter, window/close interruption, layout and canvas refresh regressions |

Coordinate tests exercise 1×/2× backing scales and 1%, 50%, 100%, 800%, and 3200% zoom, with pan and aligned origins. Native event tests draw at 50%, 100%, and 800%, then dispatch Escape and sampling through the actual canvas adapter. Domain tests check explicit alpha outcomes on transparent, opaque and partially transparent pixels, partial edge erasure, imported JPEG erasure, exact hard square Pencil areas, and sparse-point continuity for all three drawing tools. The preview assembly is compared byte-for-byte with a full composite, including layer opacity and patch boundaries.

Native painting tests prove the committed model remains unchanged throughout drag, an entire stroke undoes back to clean state, redo restores exact bytes, and save/reopen preserves metadata and pixels. Tests also cover active layer deletion and selection during a gesture, window interruption, close, hover, tool/size/color changes and sampling without history. PNG fixtures use colors that round-trip exactly through ImageIO; the native format remains the authority for all low-alpha bytes. JPEG assertions include lossy tolerance and the white matte.

## Interactive checks actually performed

The optimized app was exercised through native computer-use input, accessibility-tree inspection, and screenshots in the system dark appearance:

- Created a 128×96 transparent image; drew a fast long Brush stroke at fit/high zoom and observed continuous round output.
- Cmd-Z removed the entire stroke, and Cmd-Shift-Z restored it. Eraser cut through the stroke and exposed checkerboard. The dual-color round footprint and square Pencil footprint were visible.
- Selected Pencil and drew hard square-edged marks. Entered a size of 1 through the numeric field, confirmed the accessibility value changed, and drew a thin line. Tool menu selected values, size units, disabled sampling size, color well labels, and layer control state were inspected.
- Sampled empty canvas with Eyedropper and observed foreground `rgba(0,0,0,0)`, then sampled the black mark and observed `rgba(0,0,0,1)` in the accessibility tree.
- Inspected the final native control strip on a 1100-point window. A separate scoped UI review returned `ship` with no material findings, explicitly limiting that verdict to supplied screenshot/source evidence.

Live checks caught and led to regressions for unchanged SwiftUI layouts cancelling gestures and a stale canvas representable after commit. Both fixes were subsequently exercised in the release app, with visible brush/eraser output and native undo.

Some native AX interactions needed a separate observation before the next action to establish focus. Native color wells exposed the expected panel action, but attempts to open the color panel did not yield an observable panel in the computer-use surface. **Color-panel editing/alpha interaction is therefore unverified live**, not counted as passed. Conversion, foreground/background state and neutral dirty semantics have automated coverage.

## Remaining boundaries

No claim is made for actual VoiceOver speech/navigation, light appearance, physical non-Retina/multiple displays, real trackpad input, minimum-size layout, or a full manual save/export/reopen cycle with painted content. Those file paths are exercised by automated native-document and image-codec tests. Live testing did not establish background color-panel editing, modifier-drag panning, focus-loss mid-drag, or final pixel precision visually; the corresponding ownership, transform, and interruption rules have deterministic tests where listed above. The canvas exposes an image description and interaction help, not a claim of full nonvisual raster editing.

[Painting measurements](painting.md) document repeatable CPU timing, all observed timing ranges, known memory costs, and limitations. They are not a frame-rate guarantee. Full-raster undo history remains memory-intensive; property edits and undo/redo still use synchronous full compositing. Maximum-size images, worst-case 128-layer stacks, and peak whole-app memory have not been benchmarked. Native package saves remain synchronous/uncompressed, and signing is local ad-hoc with no notarization or release configuration.

## Final validation

Run from a clean package state:

```sh
swift package clean
Scripts/validate.sh
```

The clean run completed successfully: strict recursive swift-format lint, plist configuration, all 96 functions / 154 executions, optimized app/benchmark builds, ad-hoc bundle signature verification, and diff whitespace checks passed. No compiler warnings were emitted. Benchmark outputs are produced on demand; generated apps, screenshots, temporary fixtures, logs, and user-specific files are excluded from commits.

Recommended reviewer follow-up: native color-panel alpha editing, VoiceOver, physical multi-display coordinates, minimum-size/light layouts, and large-image interactive latency. The next feature interval should build a small selection/region-editing foundation on the existing raster replacement and stroke transaction boundary, after review of this branch.

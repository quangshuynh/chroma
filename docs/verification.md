# Verification — Interval 2

Verified October 7, 2026, on macOS 26.6.2 (25G83), Apple Silicon, Xcode 27.0 (27A266a), and Swift 6.4, targeting macOS 14+. macOS 14, Intel hardware, and the remote CI runner have not been personally exercised.

## Final automated validation

`swift package clean` followed by `Scripts/validate.sh` completed successfully. This covered strict recursive swift-format lint, plist validation, a fresh test build, the complete test suite, an optimized app-bundle build, ad-hoc signature verification, and diff whitespace checks. The build emitted **no compiler warnings**.

There are **67 test functions in six suites, 105 executions including parameterized cases** (Interval 1 had 33 functions / 46 executions):

| Suite | Functions | Executions | Coverage |
| --- | ---: | ---: | --- |
| DocumentTests | 6 | 12 | Dimension boundaries, transparent/white blank pixels, viewport/content separation |
| ViewportTests | 8 | 8 | Fit, clamping, anchor zoom, physical-pixel sizing, Retina alignment, pan constraints |
| ImageCodecTests | 13 | 20 | PNG fidelity, JPEG matte, TIFF/HEIC imports, alpha, EXIF orientation, malformed/oversized input, atomic exports |
| LayerTests | 19 | 28 | Add/delete/fallback, last-layer policy, immutable duplication, identity, names, order, visibility/opacity, limits, exact alpha math, merge/flatten, layered PNG/JPEG export |
| NativeCodecTests | 8 | 24 | Disk/FileWrapper round trips, every persisted field, all low-alpha values, deterministic manifest, import naming, malformed manifests/files, symlinks, oversized sparse files |
| NativeDocumentTests | 13 | 13 | Native safe saves/replacement/reopen/failure, source preservation, dirty state, undo/redo, saved-state traversal, neutral selection/navigation/export, cache reuse, window/menu updates, draft-name undo regression |

The parameterized codec tests use actual ImageIO PNG/JPEG/TIFF/HEIC encodings. Pixel tests include explicit expected premultiplied channel values and final JPEG matte tolerances. Native files preserve exact working bytes across every alpha value from 0 through 255. Tests reject missing/duplicate IDs, unsupported schema versions, invalid dimensions/opacity/names/pixel formats, missing/truncated/extra layer files, invalid premultiplied pixels, and filesystem symlinks at every package level.

The AppKit tests instantiate real `NSDocument`/window/canvas objects and native UndoManagers. They verify that seven consecutive layer edits undo to clean content and redo with stable IDs, that save clears dirty state, that undo returns to the saved state, and that export does not replace the editable document. A separate regression covers editing a name, changing selection, undoing, losing text focus, and retaining redo without a stale draft creating another edit.

## Interactive checks actually performed

Unlike Interval 1, computer-use access was available. Native accessibility-tree inspection and screenshots were used with the locally built app and temporary fixtures outside the repository.

- Created a 64 × 48 transparent document; visually inspected its checkerboard and native Layers inspector in the system's dark appearance.
- Added a layer, renamed it with Return, duplicated it, moved it down, changed opacity through the accessibility decrement action, and toggled visibility. Observed the updated names, counts, values, and enabled/disabled controls.
- Exercised Cmd-Z/Cmd-Shift-Z for visibility and Cmd-Z to restore two layers after Merge Down.
- Opened a two-layer `.chroma` fixture through the native Open panel. Visually confirmed red at 50% over blue produced purple on the left and blue on the right.
- Hid a layer and saved the existing native package with Cmd-S; inspected the on-disk manifest to confirm the visibility change. Used Save As to create a second native package, closed it without an unsaved prompt, and reopened it with both layers, names, visibility, and opacity intact.
- Exported PNG through the File menu and JPEG through its shortcut. Checked the panel explanations and confirmed the layered document retained its identity and stack; output files appeared beside the temporary native package. Exact output pixels/matte are verified by the automated tests.
- Opened an ordinary transparent PNG and observed one layer named from the source. Added a transparent layer and saved it as a `.chroma` package through the native Save panel, preserving the source PNG.
- Inspected accessibility labels/values for the layer list, selected rows, visibility toggles, name field, opacity slider, and disabled final-layer deletion/reorder controls. Keyboard Up/Down selection was exercised in the release build.
- Launched the final optimized bundle and inspected its dark-mode layout after the draft-name fix and removal of dense slider tick marks. The independent source review scored the rename correction resolved; the automated regression covers the complete post-fix undo sequence.

Live control sometimes required separate steps to let native sheets establish focus. The final release also coexisted with an earlier debug process; some attempted direct row clicks/shortcuts did not produce an observable change. Those attempts are not counted as passed interaction checks. The complete final-release rename/undo sequence is supported by automated AppKit coverage, not a claimed successful live replay.

## Remaining verification boundaries

Actual VoiceOver speech/navigation was **not** exercised. AX labels and selected/enabled state inspection are useful evidence but not a VoiceOver pass. Light appearance, minimum-size/resized windows, physical mouse drag/slider-drag coalescing, real trackpad pinch/pan, non-Retina/multiple displays, Finder double-click associations, replacement-confirmation cancellation, and close/quit with multiple dirty windows remain manual checks. White blank pixels, delete, flatten, malformed-project rejection, and most error paths have automated coverage; no additional hands-on claim is made for them.

No performance or peak-memory benchmark is claimed. Compositing and native package encoding remain synchronous; raw native rasters are uncompressed, and undo can retain removed/merged buffers beyond the current-stack pixel bound. Merge Down is deliberately limited to the bottom pair for exact 8-bit appearance; arbitrary middle merges are deferred. Import remains 8-bit sRGB with metadata loss and first/primary-image semantics. Signing is local ad-hoc, with no notarization or release configuration.

## Suggested reviewer pass

1. Exercise the remaining manual boundaries above, especially a long opacity drag followed by one Undo and actual VoiceOver navigation.
2. Edit a layer name without Return, select another layer, select back, and use Undo/Redo; confirm no stale rename is recommitted.
3. Verify both Save and cancelled Save As on imported and native documents, plus close/quit prompts for multiple edited windows.
4. Check small/large canvases and representative larger stacks for acceptable UI latency before expanding the pixel-editing scope.

No PR, merge, tag, release, or Interval 3 work is part of this interval.

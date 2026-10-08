# Chroma

Chroma is an early-development native macOS raster image editor, inspired by the approachable workflow of paint.net. It is built with Swift, SwiftUI, AppKit, Core Graphics, and ImageIO. It supports layered documents, pixel painting, compositing, native saves, and stroke-level undo.

## What works

- Create an image with pixel dimensions and a transparent or white background.
- Open PNG, JPEG, TIFF, and HEIC images with native file dialogs or Finder.
- View transparency over a checkerboard that is never included in saved pixels.
- Zoom from 1% to 3200%, fit the image, or show actual size. At 100%, one image pixel occupies one physical display pixel, including on Retina displays.
- Pan by scrolling, Option-dragging the canvas, or using arrow keys while the canvas has focus. Shift-arrow moves farther; trackpad pinch zooms around the pointer.
- Inspect dimensions, working color space, and depth. The native window title shows the filename and unsaved-change indicator.
- Paint the selected visible layer with Pencil or Brush, erase to transparency, and sample the visible composite with Eyedropper.
- Choose foreground/background colors with native color wells, swap them, and set a 1–512 px diameter. Pencil uses hard square marks; Brush and Eraser use round edges.
- Undo or redo a whole stroke in one step. Escape cancels an unfinished stroke without changing document pixels.
- Add, duplicate, rename, delete, reorder, show/hide, and adjust the opacity of raster layers in the native Layers inspector.
- Undo/redo document edits, merge the bottom two layers, or flatten the stack while preserving transparency.
- Save editable `.chroma` packages; export a composited PNG with alpha or JPEG with an explicit white matte.
- Use multiple document windows, native close/quit prompts, and the system light or dark appearance.

**Save preserves layers in a native `.chroma` document.** Imported images start clean and must choose a Chroma destination when saved. Existing native documents save to their current destination; Save As creates a copy. PNG/JPEG export leaves the document, its destination, and its unsaved state unchanged. New images start unsaved. Navigation, active-layer selection, hovering, tool/size/color changes, and Eyedropper sampling never mark content modified. Hidden and zero-opacity layers must be made visible before painting.

The inspector lists the topmost layer first. Move Up/Down controls provide explicit, accessible reordering. The final layer cannot be deleted. Rename with Return or by leaving the name field; opacity drags apply on release as one undo step. Merge Down is currently available only for the bottom two layers, where the 8-bit compositor can preserve exact pixels. Flatten Image handles the complete stack and retains alpha. Both operations are undoable.

## Build and run

Requires macOS 14 or later and Xcode 16 or later with Swift 6 and the command-line tools selected. There are no third-party dependencies. The application is currently for local development, not a Developer ID signed or notarized release.

```sh
Scripts/build-app.sh
open .build/debug/Chroma.app
```

For a release-optimized local build:

```sh
Scripts/build-app.sh release
open .build/release/Chroma.app
```

The script builds the executable, supplies the app bundle metadata and image document associations, and ad-hoc signs the bundle. It does not register Chroma as the default image viewer. Run the bundle for native file handling; `swift run Chroma` lacks the bundle metadata. Open `Package.swift` in Xcode to browse, debug, and test the package.

```sh
swift test                    # Core tests plus AppKit document integration tests
Scripts/validate.sh           # Formatting, tests, release build, bundle signature, diff checks
xcrun swift-format format --in-place --recursive Package.swift Sources Tests
```

Use `swift package clean` before validation for a clean build. CI runs validation on a macOS runner. [Verification notes](docs/verification.md) distinguish automated coverage from interactive checks.

## Keyboard commands

| Action | Shortcut |
| --- | --- |
| New image | ⌘N |
| Open image | ⌘O |
| Save Chroma document | ⌘S |
| Save As | ⇧⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Export JPEG | ⇧⌘E |
| Zoom in / out | ⌘= / ⌘− |
| Actual size | ⌘0 |
| Fit image | ⇧⌘0 |
| Toggle inspector | ⌥⌘I |
| Close window | ⌘W |

## Formats and limits

| Format | Open | Output |
| --- | --- | --- |
| Chroma (`.chroma`) | Editable layers | Editable layers, exact working pixels |
| PNG | Yes, alpha preserved | Lossless, alpha preserved |
| JPEG | Yes, orientation applied | 92% quality, white transparency matte |
| TIFF | First image/page only, alpha preserved | No |
| HEIC | Primary image through the installed Apple decoder | No |

Ordinary image inputs are checked against the installed ImageIO decoders. Images are decoded once, with orientation applied, and normalized to **8-bit premultiplied RGBA in sRGB**. This is not an archival metadata or high-bit-depth workflow: original metadata, HDR range, additional pages/frames, auxiliary depth images, and original color profiles are not retained in output. Source files are never changed just by opening them.

Per-raster limits are 16,384 pixels per side, 32 million pixels total, and 256 MB per input file. Dimensions and file size are checked before pixel decoding. A document has at most 128 layers and 128 million aggregate layer pixels. A maximum-sized single raster is approximately 128 MB; decoder/encoder intermediates, composite buffers, undo history, and multiple windows increase memory use. Layer-operation compositing, undo/redo compositing, and native package saves are synchronous. Painting uses affected-region previews and assembles the final composite at stroke end. Background creation, opening, and PNG/JPEG export run expensive work away from the UI. Native version 1 uses uncompressed RGBA layer files to avoid low-alpha rounding on save; see the [format specification](docs/native-format.md).

## Architecture

- **ChromaCore** contains validated dimensions, immutable raster storage, the document/layer model, mutation APIs, deterministic normal-alpha compositor, native package codec, image codecs, viewport math, and the pixel stroke engine.
- **ChromaApp** adapts content to `NSDocument`, native undo, safe saving, dirty state, and windows. SwiftUI provides forms and the Layers inspector; an AppKit canvas draws the cached composite and handles navigation.
- **Tests** cover layer invariants, exact compositing, native round trips and malformed packages, all ordinary image formats, export, viewport neutrality, native undo/redo, painting/alpha/interpolation, cancellation, and saved-state traversal.

See [painting behavior and measured performance](docs/painting.md) for tool semantics, memory costs, and the repeatable benchmark.

Content owns pixels, the document boundary controls mutations and render invalidation, and each editor owns transient presentation state. Undo retains immutable raster references instead of copying image buffers for property edits. See [architecture decisions](docs/architecture.md).

## Not implemented yet

Selections, fill, gradients, blend modes, masks, transforms, full History, text, shapes, effects, adjustments, PSD, RAW development, plugins, AI, cloud accounts, and collaboration are outside this version. The compact tool strip exposes only implemented tools.

Licensed under the [MIT License](LICENSE).

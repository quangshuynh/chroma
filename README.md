# Chroma

Chroma is an early-development native macOS raster image editor, inspired by the approachable workflow of paint.net. It is built with Swift, SwiftUI, AppKit, Core Graphics, and ImageIO. The current version establishes the document and canvas foundation; it does not yet edit image pixels.

## What works

- Create an image with pixel dimensions and a transparent or white background.
- Open PNG, JPEG, TIFF, and HEIC images with native file dialogs or Finder.
- View transparency over a checkerboard that is never included in saved pixels.
- Zoom from 1% to 3200%, fit the image, or show actual size. At 100%, one image pixel occupies one physical display pixel, including on Retina displays.
- Pan by scrolling, dragging the canvas, or using arrow keys while the canvas has focus. Shift-arrow moves farther; trackpad pinch zooms around the pointer.
- Inspect dimensions, working color space, and depth. The native window title shows the filename and unsaved-change indicator.
- Save a lossless PNG with alpha or export a JPEG with transparency explicitly flattened onto white.
- Use multiple document windows, native close/quit prompts, and the system light or dark appearance.

**Save PNG always asks for a destination**, even for an already-open PNG. Replacing an existing file requires the native confirmation. A successful PNG save makes that file the document's destination and clears its unsaved state. JPEG export is a copy: it does not change the open document or its unsaved state. New images are unsaved until saved as PNG; imported images start clean. Navigation does not modify images.

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
| Save PNG | ⌘S |
| Export JPEG | ⇧⌘E |
| Zoom in / out | ⌘= / ⌘− |
| Actual size | ⌘0 |
| Fit image | ⇧⌘0 |
| Toggle image information | ⌥⌘I |
| Close window | ⌘W |

## Formats and limits

| Format | Open | Output |
| --- | --- | --- |
| PNG | Yes, alpha preserved | Lossless, alpha preserved |
| JPEG | Yes, orientation applied | 92% quality, white transparency matte |
| TIFF | First image/page only, alpha preserved | No |
| HEIC | Primary image through the installed Apple decoder | No |

Input types are restricted to these formats and checked against the installed ImageIO decoders. Images are decoded once, with orientation applied, and normalized to **8-bit premultiplied RGBA in sRGB**. This is not an archival metadata or high-bit-depth workflow: original metadata, HDR range, additional pages/frames, auxiliary depth images, and original color profiles are not retained in output. Source files are never changed just by opening them.

Limits are 16,384 pixels per side, 32 million pixels total, and 256 MB per input file. Dimensions and file size are checked before pixel decoding. A maximum-sized working raster is approximately 128 MB; decoding and encoding can temporarily require several buffers, and multiple windows increase memory use. PNG encoding currently runs within the native synchronous save operation. Background creation, opening, and JPEG encoding avoid blocking the UI during their expensive work.

## Architecture

- **ChromaCore** contains validated dimensions, immutable raster storage, the persistent `ImageDocument` model, ImageIO codecs, and pure viewport math. It has no SwiftUI or AppKit dependency.
- **ChromaApp** uses `NSDocument` for files, safe PNG writes, dirty state, and window lifecycle. SwiftUI provides forms, editor controls, and the small image inspector. An AppKit view renders the retained Core Graphics composite and handles navigation.
- **Tests** cover validation, orientation, pixel and alpha round trips, file failures, viewport calculations, and native document lifecycle behavior.

The persistent model owns pixels, while each editor window owns its viewport. `ImageDocument.composite` is the rendering boundary for a future layer compositor. There are deliberately no speculative layer, tool, or history implementations. See [architecture decisions](docs/architecture.md).

## Not implemented yet

Layers, painting, selections, undoable pixel operations, History, text, shapes, effects, adjustments, a native layered project format, PSD, RAW development, plugins, AI, cloud accounts, and collaboration are outside this version. The left side remains available for a future tool rail; no inactive tools or placeholder inspectors are shown.

Licensed under the [MIT License](LICENSE).

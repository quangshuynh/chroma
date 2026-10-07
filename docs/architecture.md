# Architecture

## Ownership and boundaries

`PixelSize` is the sole dimension-validation boundary. `RasterSurface` owns a retained immutable Core Graphics bitmap snapshot, normalized to 8-bit premultiplied RGBA with explicit byte ordering and sRGB color space. A `CGImage` here is pixel storage and an interchange snapshot, not a view or `NSImage` representation. Copying the value retains storage rather than copying a full raster.

`ImageDocument` is the persistent content model. Its `composite` property is currently the single raster's image. The future evolution is `ImageDocument → layer stack → raster layer → pixel storage`, with a compositor producing the same immutable rendering snapshot. Layer identifiers, selections, transforms, blend modes, undo transactions, and history are intentionally deferred until their behavior is specified. Future model mutations should replace the composite and notify the window, rather than storing edits inside the canvas view. The current window snapshot is immutable because there are no content editing actions yet.

`ChromaDocument` adapts this content to `NSDocument`. It owns file identity, native safe writing, unsaved state, and document windows. Its model storage is lock-protected because AppKit may open documents concurrently on worker threads. The lock's unchecked Sendable conformance is confined to this small storage box; only immutable `ImageDocument` values cross the boundary. `NSDocument` owns the rest of the lifecycle on the main actor. Newly created documents are dirty; imports are clean. File errors propagate to native error presentation.

`EditorState` and `CanvasNSView` own presentation state. Zoom, pan, inspector visibility, display scale, and checkerboard color cannot enter the file codec. SwiftUI body evaluation never decodes or constructs a full-resolution image. The canvas redraws the same retained snapshot. It visits only visible checkerboard cells, even when the scaled image is enormous.

## Native shell

The app uses an AppKit entry point and document controller, with SwiftUI hosted inside ordinary resizable document windows. This keeps the responder chain, file dialogs, close/quit prompts, window titles, focus, and application menus native. `NewDocumentView` validates text before allocation and creates its raster off the main actor. Controls inherit system appearance and fonts. Image information occupies the right side; the center is the image workspace. A future left tool rail can join that workspace without changing pixel ownership.

A Swift package provides a reproducible build and testing interface. The bundle script supplies `Info.plist`, native document type associations, and local ad-hoc signing. No generated Xcode project, user-specific settings, package dependencies, or release credentials are needed.

## File semantics

ImageIO recognizes PNG, JPEG, TIFF, and HEIC by content, with support restricted to installed decoders. File size and encoded dimensions are checked before decoding; EXIF orientation is applied once at full resolution. Only the first/primary image is imported. Normalization intentionally trades original profile, high bit depth, metadata, animation, and additional pages for a predictable working pixel format. Decode failures leave the existing document untouched.

Save PNG always presents a destination. `NSDocument` performs safe writing and clears dirty state only after success. The app disables autosaving in place so imports are not silently rewritten. JPEG export uses a detached task with an immutable snapshot, a fixed 92% quality, and an explicit white matte. Its native panel explains the alpha loss. Encoding finishes before an atomic replacement writes the file; failures leave the document's identity and dirty state unchanged. The checkerboard is never passed to either encoder.

There is no native project format yet. A successful JPEG export does not fulfill the pending PNG save for a new unsaved document. This is intentional: the export is lossy and its alpha has been discarded.

## Viewport and memory

Zoom is physical display pixels per image pixel. At 100%, a 1000-pixel image spans 500 points on a 2× Retina display. Image origins align to display pixels, but dimensions are never rounded outward; doing so would stretch odd-sized rasters. Integer and high zoom use nearest-neighbor interpolation; reduced zoom uses high-quality display interpolation without altering pixels.

Fit leaves 24 points of margin per side and tracks workspace resizing until the user pans or chooses a fixed zoom. Pinch zoom preserves the image position under the pointer. Panning is constrained so at least part of the image remains reachable. Dragging is a hand interaction throughout this interval; a future tool mode can make it temporary without changing viewport math.

The 32-million-pixel cap bounds one working buffer to about 128 MB, not total process memory. Decoder, normalization, PNG/JPEG encoding, and matte creation may overlap buffers. Multiple documents compound that cost. PNG save remains synchronous; move its encoding to a snapshot-based asynchronous NSDocument write path if measured latency warrants it. There is no tiled cache, Metal pipeline, or speculative render scheduler.

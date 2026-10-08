# Chroma native document, version 1

Extension: **`.chroma`**. Exported type: `com.chroma.editor.document`, conforming to `com.apple.package`. Finder treats it as a document; Show Package Contents exposes its files.

```text
Artwork.chroma/
    document.json
    layers/
        <UPPERCASE-UUID>.rgba
        ...
```

The UTF-8 manifest is pretty-printed JSON with sorted keys. It contains:

```json
{
  "height": 48,
  "id": "878D0B66-D8C4-4315-A8D0-9F973508877E",
  "layers": [
    {
      "id": "934DDE98-0095-46A3-AAC7-8106D6DA0E54",
      "name": "Background",
      "opacity": 1,
      "visible": true
    }
  ],
  "pixelFormat": "rgba8-premultiplied-srgb",
  "version": 1,
  "width": 64
}
```

The layers array is bottom-to-top and must contain at least one unique layer ID. Each raster exactly matches the canvas. Layer filenames are derived from parsed UUIDs, never from paths supplied by the manifest. The document UUID identifies persistent content across native saves; opening an ordinary image starts a new document identity.

Each `.rgba` file holds exactly `width × height × 4` bytes, tightly packed row-major from the top-left pixel, with no header or row padding. Channel order is red, green, blue, alpha. Color is encoded sRGB, 8 bits per channel, premultiplied by alpha. Every color channel must be less than or equal to alpha, including zero RGB at zero alpha. Channels are bytes, so there is no endianness ambiguity.

**Why raw RGBA instead of authoritative PNG layers:** the working raster is premultiplied. PNG stores straight alpha; unpremultiplying and then premultiplying through ImageIO can change low-alpha channel bytes. Native version 1 preserves every working byte exactly. The tradeoff is larger uncompressed packages. The JSON and independent pixel files remain inspectable and versionable. No preview, compression, Quick Look extension, or thumbnail is required in version 1; those can be added in a future schema rather than becoming another authoritative representation.

## Validation and safe writes

The reader accepts only schema version 1 and the specified pixel format. It validates dimensions, the layer limit (128 layers and 128 million aggregate pixels), UUID uniqueness, nonempty trimmed names up to 255 characters without control characters, finite `0...1` opacity, exact raster sizes, and premultiplied channel validity. Required fields must be present and correctly typed. Unknown JSON keys are ignored for additive metadata compatibility; a changed encoding or semantic contract must increment the schema version.

The root must contain exactly `document.json` and the `layers` directory. That directory must contain exactly the expected UUID-derived files. Package components cannot be symbolic links. Nested files/directories in place of rasters, unexpected entries, missing pixels, invalid JSON, malformed IDs, unsupported versions, and inconsistent dimensions are rejected. The URL reader checks the manifest size (at most 1 MB) and raster file sizes before loading their contents. It constructs the entire validated document before replacing application state; there is no partial or flattened fallback.

`NSDocument` owns safe package replacement and file identity changes. The codec returns a `FileWrapper` tree; it never writes to the source while decoding. Save failure keeps the in-memory content and dirty state. Tests also round-trip packages on disk and reject real filesystem symlinks and oversized sparse raster files.

## Persistent versus session data

Persisted: schema/pixel format, document ID, canvas size, layer order, IDs, names, visibility, opacity, exact pixels/alpha.

Omitted: active layer, tool, brush size, foreground/background colors, unfinished stroke previews, zoom, pan, window state, inspector visibility, drafts, render revision, composite cache, and undo/redo history. Reopening selects the top layer and starts a new undo history. Export is never a native-document mutation.

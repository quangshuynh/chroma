# Verification

Validation was performed on October 7, 2026, on macOS 26.6.2, Apple Silicon, with Xcode 27.0 and Swift 6.4, targeting macOS 14 and later. Compatibility on macOS 14, Intel Macs, and CI-hosted machines has not been personally verified.

## Automated coverage

The suite contains 33 Swift Testing tests in four suites (46 executions when parameterized cases are counted individually):

- 6 document-model tests: size boundaries and overflow avoidance, blank alpha/white pixels, and navigation/content separation.
- 8 viewport tests: clamping, fit margins and display scale, anchor-preserving zoom, fit reset, actual size, odd-sized Retina pixel alignment, and pan bounds.
- 13 codec tests: PNG pixel/alpha fidelity, JPEG white matte, partial alpha compositing, TIFF and HEIC decoding, TIFF alpha, seven nonidentity EXIF orientations, unsupported/corrupt/truncated inputs, oversized dimensions and file size, atomic export round trips, and missing-destination failures.
- 6 AppKit integration tests: unsaved new documents, clean opens with unchanged source bytes, successful and failed native PNG saves, an instantiated window/canvas receiving zoom commands without dirtying the document, and invalid-file errors.

The format tests construct actual ImageIO-encoded PNG, JPEG, TIFF, and HEIC fixtures and decode them through the production codec. This verifies these format paths on the test machine; it does not promise every compression variant, camera-specific HEIC auxiliary image, or malformed file can be decoded. PNG and JPEG output both have round-trip checks.

Run `Scripts/validate.sh` for strict Swift formatting, all tests, an optimized app-bundle build, plist validation, signature verification, and diff whitespace checks. For a clean validation run, first run `swift package clean`. No compiler warnings are expected.

## Interactive verification boundary

The debug app bundle was launched through macOS LaunchServices and its running process was confirmed. Native document and canvas behavior was exercised through the automated AppKit tests. Those checks are not a substitute for visual inspection or real pointer/trackpad testing.

Live computer-use verification was attempted three times, but the tool remained blocked waiting for macOS Accessibility and Screen Recording permissions. Consequently, there is **no claimed hands-on verification** of the New Image form, Open/Save panels, replacement confirmation, Finder file associations, error alerts, light/dark appearance, window resizing, real trackpad gestures, or VoiceOver. No screen recording, screenshot, or simulated successful manual result is included.

Before merging, perform this short interactive pass:

1. Launch the bundled app; create both transparent and white images. Enter zero, negative, nonnumeric, and excessive dimensions and confirm Create is disabled with guidance.
2. Open PNG, JPEG, TIFF, and HEIC examples. Open a corrupt file with a supported extension and confirm an understandable error appears without replacing another document.
3. Resize the window, toggle Image Info, zoom in/out, select Actual Size and Fit, scroll and drag, and pinch on a trackpad. Check an odd-sized raster at 100% on a Retina display and, if available, move it to a non-Retina display.
4. Save a transparent PNG and reopen it. Export JPEG and confirm white instead of transparent pixels, with unchanged dimensions. Confirm neither includes the checkerboard. Choose an existing destination and verify the native replacement confirmation; cancel to preserve it.
5. Close an unsaved new image and quit with multiple windows; verify Save, Cancel, and Don't Save behavior. Confirm opening/navigating a source image does not mark it edited.
6. Check system light/dark appearances, keyboard focus, and VoiceOver labels.

There is no performance benchmark claim. Large PNG saves are synchronous; decoder and encoder intermediates can multiply memory use despite the explicit image-size cap. Distribution signing and notarization are not configured.

# Chroma interface

The editor is an operational desktop workspace. Follow AppKit window and menu conventions, system fonts and semantic colors, and SwiftUI's native form controls. Both light and dark appearances follow the system.

The window has a compact control strip, a flexible canvas, an optional 260-point Layers inspector, and an understated status strip. The tool controls wrap into two rows in compact windows. A selection summary exposes bounds without relying on outlines. Minimum window size is 640 × 520 points. The canvas uses the system workspace background; transparency uses neutral 8-point checker cells clipped to image bounds. The image itself provides the visual emphasis. The inspector uses a native selectable list with the top layer first, compact layer controls, and a bottom metadata line.

Keyboard equivalents, explicit control labels, focusable dimension fields, native validation feedback, and descriptive canvas accessibility text are required. Zoom values use tabular numerals. Unavailable future features are omitted. Native file dialogs explain editable Chroma saving, PNG transparency, and JPEG's white matte. No decorative graphics, custom fonts, motion, or fake tool controls are needed.

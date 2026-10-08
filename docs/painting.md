# Painting

Choose Pencil, Brush, Eraser, or Eyedropper from the native Tool menu above the canvas. Enter a size or use the stepper (1–512 document pixels). Foreground and Background open native color controls with alpha; the swap button makes the background the next painting color. Eraser is full strength and ignores color alpha. Eyedropper reads the visible composite, not the selected layer or checkerboard, and assigns foreground. Size is disabled for sampling, selection, and movement tools.

Pencil is a pixel-aligned square and replaces covered pixels with the selected premultiplied color. Brush is round, with a one-pixel antialiased transition and source-over alpha. Eraser uses the same round geometry but reduces all premultiplied channels, revealing lower layers or transparency. Overlapping stamps use the maximum coverage reached during a gesture. Separate gestures can accumulate opacity or erasure. No pressure, texture, dynamics, or brush preset system is implied.

A down/drag/up gesture is one native Undo step. Escape and interaction interruptions roll back unfinished strokes. Paint only on a visible, nonzero-opacity active layer; the status line explains rejected attempts. Option-drag, scroll, and arrow keys pan. Zoom and Retina scale never change document-pixel brush size. Tool/color/navigation changes and sampling are clean operations. Save and export contain only committed pixels. `.chroma` schema version 1 is unchanged.

## Selection-aware mutation

Rectangle Select and Ellipse Select are available in the same native Tool menu. `PixelStroke` captures the current binary row-span mask at mouse-down and skips unselected pixels at the existing stamp boundary; it does not duplicate the painting engine. Nil selection permits the entire layer, while an active empty mask permits no edits. Pencil replacement, Brush/Eraser edge coverage, interpolation, and maximum per-stroke coverage retain their original semantics. Selection changes cancel unfinished strokes and do not dirty content. See [selections](selections.md) for geometry, region operations, movement lifecycle, and measured performance.

## Repeatable benchmark

Run optimized builds, preferably without other builds or CPU-heavy work:

```sh
swift run -c release ChromaBench 1000 1
swift run -c release ChromaBench 1000 4
swift run -c release ChromaBench 2000 4
```

The harness creates full-canvas layers at opacity 0.7 (including the single-layer case, so the full compositor does real work). Initial duplicated rasters share immutable backing. It measures five baseline full recomposites and three fresh transactions, each with a 32 px, alpha-160 Brush and 121 sinusoidal input points across the image. Measurements separate transaction setup, raster mutation, preview recomposition, final raster creation, and final composite assembly. It also measures a full recomposite of the edited stack for comparison, though painting commit does not use it. This is engine CPU timing, not GPU frame rate or end-to-end pointer latency.

Measured October 7, 2026 on Apple M1, 16 GiB RAM, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Swift 6.4, release optimization. The desktop remained active; these are observations, not latency guarantees. Ranges include all three runs, including outliers.

| Scenario | Mutation total | Preview total | Mean input event | Worst input event | Finish raster | Assemble composite | Full composite baseline mean |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000², 1 layer | 4.95–5.48 ms | 55.23–62.79 ms | 0.50–0.56 ms | 1.53 ms | 1.96–2.25 ms | 2.51–3.00 ms | 15.63 ms |
| 1000², 4 layers | 4.81–5.10 ms | 266.19–353.37 ms | 2.24–2.96 ms | 34.94 ms | 1.92–1.95 ms | 4.57–4.88 ms | 50.78 ms |
| 2000², 4 layers | 12.01–15.27 ms | 721.22–847.45 ms | 6.06–7.13 ms | 20.20 ms | 7.73–9.95 ms | 10.34–15.39 ms | 347.64 ms |

For 1k/2k respectively, there were 159/324 stamps including the final endpoint, 2,827,264/3,360,768 preview pixels visited across the gesture, and at most four refreshed patches per input event. A full-image refresh on every event would visit 121/484 million output pixels before multiplying by layer count. The final edited full-composite comparison took 48.32–48.79 ms at 1k/four layers and 196.45–290.84 ms at 2k/four layers; assembly avoids that commit cost. Transaction setup took 0.28–4.44 ms across these scenarios. The baseline 2k mean was higher than subsequent comparison runs, illustrating scheduling/thermal variability.

## Memory and remaining costs

At 1k/2k, the working RGBA copy plus coverage requires approximately 5/20 MB, and one retained raster version for undo costs 4/16 MB. This gesture's preview cache occupied 1.02/2.20 MB. Final composite assembly additionally needs one 4/16 MB copy while the prior display image is retained. Provider bridges, transient regional buffers, encoding and OS allocations add overhead. Process peak RSS reported by `getrusage` was about 37.7 MB for 1k/four layers and 119.7 MB for 2k/four layers; these include the synthetic fixture, benchmark comparison work, and all three runs, not an isolated delta or a whole-app memory profile.

Undo history retains full immutable raster versions, not region deltas. There is no byte-budgeted history eviction. A 32-million-pixel layer can cost 128 MB per retained version, plus 160 MB of working pixels/coverage during a stroke. A stroke spanning the entire canvas can also accumulate a full-canvas preview cache. Several large documents or a long history can exhaust practical memory before current-layer limits. Region deltas are a future optimization, not part of this implementation.

Preview compositing is synchronous, scales with visible layer count, and still redraws the AppKit canvas on updates. Very large brushes and pathological long paths can be slow. Undo/redo and layer-property edits use full compositing; native saves are synchronous and uncompressed. Preview patch boundaries can have different display filtering from a full image at fractional zoom; exported/committed pixels remain exact. Physical non-Retina and multi-display painting, actual trackpad input, VoiceOver, and large-document interactive latency need further hardware checks.

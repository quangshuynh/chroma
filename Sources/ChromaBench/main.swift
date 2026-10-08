import ChromaCore
import CoreGraphics
import Darwin
import Foundation

// Repeat with: swift run -c release ChromaBench [side] [layers]
let side = Int(CommandLine.arguments.dropFirst().first ?? "1000") ?? 1000
let layerCount = Int(CommandLine.arguments.dropFirst(2).first ?? "4") ?? 4
let size = try PixelSize(width: side, height: side)
guard (1...16).contains(layerCount) else { fatalError("Use 1...16 layers") }
var document = ImageDocument(raster: try RasterSurface(size: size, background: .white))
for _ in 1..<layerCount { try document.apply(.duplicate(document.activeLayerID)) }
for layer in document.layers { try document.apply(.opacity(layer.id, 0.7)) }
let settings = StrokeSettings(tool: .brush, diameter: 32, color: EditorColor(red: 45, green: 95, blue: 210, alpha: 160))
func time<T>(_ action: () throws -> T) rethrows -> (T, Double) {
    let start = CFAbsoluteTimeGetCurrent()
    let value = try action()
    return (value, (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
var baseline = 0.0
for _ in 0..<5 {
    let (_, elapsed) = try time { try LayerCompositor.composite(document) }
    baseline += elapsed
}
print("side=\(side), layers=\(layerCount), 32px Brush, 121 input points, release build")
print(String(format: "full_composite_mean_ms=%.3f (5 runs)", baseline / 5))
for run in 1...3 {
    let (stroke, setup) = try time { try PixelStroke(document: document, settings: settings) }
    var mutation = 0.0
    var preview = 0.0
    var maximumEvent = 0.0
    var maxPatchCount = 0
    for index in 0...120 {
        let fraction = Double(index) / 120
        let point = CGPoint(
            x: 40 + fraction * Double(side - 80), y: Double(side) * (0.5 + 0.2 * sin(fraction * .pi * 2)))
        let (_, stampTime) = time { stroke.append(point) }
        let (patches, previewTime) = try time { try stroke.refreshPreview() }
        mutation += stampTime
        preview += previewTime
        maximumEvent = max(maximumEvent, stampTime + previewTime)
        maxPatchCount = max(maxPatchCount, patches.count)
    }
    let base = try LayerCompositor.composite(document)
    let (raster, finishTime) = try time { try stroke.finish(in: document) }
    let (_, assemblyTime) = try time { try stroke.compositedPreview(over: base) }
    var edited = document
    if let raster { try edited.replaceRaster(raster, for: stroke.layerID) }
    let (_, commitComposite) = try time { try LayerCompositor.composite(edited) }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let previewBytes = stroke.previews.values.reduce(0) { $0 + $1.raster.size.width * $1.raster.size.height * 4 }
    print(
        String(
            format:
                "run=%d setup_ms=%.3f mutation_ms=%.3f previews_ms=%.3f mean_event_ms=%.3f max_event_ms=%.3f finish_ms=%.3f assemble_ms=%.3f full_commit_composite_ms=%.3f",
            run, setup, mutation, preview, (mutation + preview) / 121, maximumEvent, finishTime, assemblyTime,
            commitComposite))
    print(
        "stamps=\(stroke.stampCount) preview_pixels=\(stroke.previewPixelCount) max_patches_per_event=\(maxPatchCount) preview_cache_bytes=\(previewBytes) working_plus_coverage_bytes=\(side * side * 5) one_undo_raster_bytes=\(side * side * 4) process_peak_rss_bytes=\(usage.ru_maxrss)"
    )
}

// Region workload: 128px ellipse, 60 distinct translations, plus a half-canvas ellipse.
for extent in [min(128, side / 2), side / 2] {
    let (mask, geometryTime) = time {
        SelectionMask.ellipse(CGRect(x: side / 4, y: side / 4, width: extent, height: extent), size: size)
    }
    let (_, outlineTime) = time { mask.outline() }
    let (move, setupTime) = try time { try PixelMove(document: document, selection: mask) }
    var elapsed = 0.0
    var maximum = 0.0
    for index in 1...60 {
        let (_, eventTime) = try time { try move.update(dx: index, dy: -index) }
        elapsed += eventTime
        maximum = max(maximum, eventTime)
    }
    let (_, finishTime) = try time { try move.finish(in: document) }
    let (_, deleteTime) = try time { try RegionEditing.delete(document.activeLayer.raster, selection: mask) }
    let (_, cropTime) = try time { try RegionEditing.crop(document, selection: mask) }
    print(
        String(
            format:
                "selection_extent=%d geometry_ms=%.3f outline_ms=%.3f move_setup_ms=%.3f move_mean_event_ms=%.3f move_max_event_ms=%.3f move_finish_ms=%.3f delete_ms=%.3f crop_ms=%.3f preview_pixels=%d",
            extent, geometryTime, outlineTime, setupTime, elapsed / 60, maximum, finishTime, deleteTime, cropTime,
            move.previewPixelCount))
}

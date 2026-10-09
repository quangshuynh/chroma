import CoreGraphics
import Foundation

public enum RegionEditing {
    /// Copy selected active-layer pixels into their bounding rectangle, zero outside the mask.
    public static func copy(_ raster: RasterSurface, selection: SelectionMask?) throws -> RasterSurface? {
        let mask = selection ?? .all(size: raster.size)
        guard mask.size == raster.size else { throw LayerError.invalidRaster }
        guard let rect = mask.bounds else { return nil }
        let size = try PixelSize(width: Int(rect.width), height: Int(rect.height))
        var bytes = Data(count: size.width * size.height * 4)
        let source = raster.rgbaBytes
        bytes.withUnsafeMutableBytes { raw in
            source.withUnsafeBytes { input in
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    for span in mask.spans(at: y) {
                        let destination = ((y - Int(rect.minY)) * size.width + span.lowerBound - Int(rect.minX)) * 4
                        raw.baseAddress!.advanced(by: destination).copyMemory(
                            from: input.baseAddress!.advanced(by: (y * raster.size.width + span.lowerBound) * 4),
                            byteCount: span.count * 4)
                    }
                }
            }
        }
        return try RasterSurface(size: size, premultipliedRGBA: bytes)
    }

    public static func delete(_ raster: RasterSurface, selection: SelectionMask?) throws -> RasterSurface? {
        let mask = selection ?? .all(size: raster.size)
        guard mask.size == raster.size else { throw LayerError.invalidRaster }
        let original = raster.rgbaBytes
        var bytes = original.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        for y in 0..<raster.size.height {
            for span in mask.spans(at: y) {
                bytes.resetBytes(
                    in: (y * raster.size.width + span.lowerBound) * 4..<(y * raster.size.width + span.upperBound) * 4)
            }
        }
        guard bytes != original else { return nil }
        return try RasterSurface(size: raster.size, premultipliedRGBA: bytes)
    }

    public static func crop(_ document: ImageDocument, selection: SelectionMask) throws -> ImageDocument? {
        guard selection.size == document.size else { throw LayerError.invalidRaster }
        guard let rect = selection.bounds, rect.size != document.size.cgSize else { return nil }
        let rectangular = SelectionMask.rectangle(rect, size: document.size)
        let layers = try document.layers.map { layer in
            try RasterLayer(
                id: layer.id, name: layer.name,
                raster: copy(layer.raster, selection: rectangular)!,
                isVisible: layer.isVisible, opacity: layer.opacity)
        }
        return try ImageDocument(
            id: document.id, size: layers[0].raster.size, layers: layers, activeLayerID: document.activeLayerID)
    }

    /// A new canvas-sized layer above the active layer, clipped at the right/bottom canvas edges.
    public static func paste(_ raster: RasterSurface, into document: ImageDocument) throws -> ImageDocument {
        guard document.canAddLayer else { throw LayerError.layerLimit }
        var bytes = Data(count: document.size.width * document.size.height * 4)
        let source = raster.rgbaBytes
        let width = min(raster.size.width, document.size.width)
        let height = min(raster.size.height, document.size.height)
        bytes.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                for y in 0..<height {
                    output.baseAddress!.advanced(by: y * document.size.width * 4).copyMemory(
                        from: input.baseAddress!.advanced(by: y * raster.size.width * 4), byteCount: width * 4)
                }
            }
        }
        let layer = try RasterLayer(
            name: "Pasted Image", raster: RasterSurface(size: document.size, premultipliedRGBA: bytes))
        var layers = document.layers
        layers.insert(layer, at: document.activeIndex + 1)
        return try ImageDocument(id: document.id, size: document.size, layers: layers, activeLayerID: layer.id)
    }
}

/// Idle is nil at the owner. A transaction retains one immutable starting document and mask.
/// Updates produce only a regional replacement; neither source nor authoritative content changes.
public final class PixelMove {
    public let source: ImageDocument
    public let selection: SelectionMask
    public private(set) var dx = 0
    public private(set) var dy = 0
    public private(set) var preview: StrokePreview?
    public private(set) var previewPixelCount = 0
    private var replacement: RasterSurface?

    public init(document: ImageDocument, selection: SelectionMask) throws {
        guard selection.size == document.size, selection.bounds != nil else { throw LayerError.invalidRaster }
        guard document.activeLayer.isVisible, document.activeLayer.opacity > 0 else {
            throw PaintingError.unavailableLayer
        }
        self.source = document
        self.selection = selection
    }
    public func validate(_ document: ImageDocument) throws {
        guard document.id == source.id, document.renderRevision == source.renderRevision,
            document.activeLayerID == source.activeLayerID
        else { throw PaintingError.staleStroke }
    }
    public var movedSelection: SelectionMask { selection.translated(dx: dx, dy: dy) }

    public func update(dx: Int, dy: Int) throws {
        let dx = min(source.size.width, max(-source.size.width, dx))
        let dy = min(source.size.height, max(-source.size.height, dy))
        guard self.dx != dx || self.dy != dy else { return }
        if dx == 0 && dy == 0 {
            self.dx = 0
            self.dy = 0
            preview = nil
            replacement = nil
            return
        }
        let canvas = CGRect(origin: .zero, size: source.size.cgSize)
        let rect = selection.bounds!.union(selection.bounds!.offsetBy(dx: Double(dx), dy: Double(dy))).intersection(
            canvas)
        let width = Int(rect.width)
        let height = Int(rect.height)
        var bytes = Data(count: width * height * 4)
        let original = source.activeLayer.raster.rgbaBytes
        bytes.withUnsafeMutableBytes { output in
            let destination = output.bindMemory(to: UInt8.self)
            original.withUnsafeBytes { input in
                let pixels = input.bindMemory(to: UInt8.self)
                // Copy rows once, then clear source spans before compositing destination spans.
                // Traversing spans avoids a membership lookup for every pixel in the rectangle.
                for row in 0..<height {
                    let y = Int(rect.minY) + row
                    let sourceOffset = (y * source.size.width + Int(rect.minX)) * 4
                    output.baseAddress!.advanced(by: row * width * 4).copyMemory(
                        from: input.baseAddress!.advanced(by: sourceOffset), byteCount: width * 4)
                    for span in selection.spans(at: y) {
                        let offset = (row * width + span.lowerBound - Int(rect.minX)) * 4
                        output.baseAddress!.advanced(by: offset).initializeMemory(
                            as: UInt8.self, repeating: 0, count: span.count * 4)
                    }
                }
                for row in 0..<height {
                    let y = Int(rect.minY) + row
                    let sy = y - dy
                    for span in selection.spans(at: sy) {
                        let lower = max(0, span.lowerBound + dx)
                        let upper = min(source.size.width, span.upperBound + dx)
                        guard lower < upper else { continue }
                        for x in lower..<upper {
                            let target = (row * width + x - Int(rect.minX)) * 4
                            let src = (sy * source.size.width + x - dx) * 4
                            let remaining = 1 - Double(pixels[src + 3]) / 255
                            for channel in 0..<4 {
                                destination[target + channel] = UInt8(
                                    min(
                                        255,
                                        (Double(pixels[src + channel]) + Double(destination[target + channel])
                                            * remaining).rounded()))
                            }
                        }
                    }
                }
            }
        }
        let raster = try RasterSurface(size: PixelSize(width: width, height: height), premultipliedRGBA: bytes)
        let composite = try LayerCompositor.compositeRegion(
            source, rect: rect, replacing: source.activeLayerID,
            bytes: bytes, replacementRect: rect)
        self.dx = dx
        self.dy = dy
        replacement = raster
        preview = StrokePreview(rect: rect, raster: composite)
        previewPixelCount += width * height
    }

    public func finish(in document: ImageDocument) throws -> RasterSurface? {
        try validate(document)
        guard let replacement, let preview else { return nil }
        let original = source.activeLayer.raster.rgbaBytes
        var result = original.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        let bytes = replacement.rgbaBytes
        for y in 0..<replacement.size.height {
            let dst = ((Int(preview.rect.minY) + y) * source.size.width + Int(preview.rect.minX)) * 4
            let src = y * replacement.size.width * 4
            result.replaceSubrange(
                dst..<dst + replacement.size.width * 4, with: bytes[src..<src + replacement.size.width * 4])
        }
        guard result != original else { return nil }
        return try RasterSurface(size: source.size, premultipliedRGBA: result)
    }
}

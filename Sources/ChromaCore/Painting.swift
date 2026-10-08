import CoreGraphics
import Foundation

public enum PaintTool: String, CaseIterable, Sendable {
    case pencil = "Pencil"
    case brush = "Brush"
    case eraser = "Eraser"
    case eyedropper = "Eyedropper"
}

/// Straight-alpha, encoded sRGB editor color. Raster bytes are premultiplied separately.
public struct EditorColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    public init(sRGBRed red: Double, green: Double, blue: Double, alpha: Double) {
        func byte(_ value: Double) -> UInt8 {
            UInt8((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded())
        }
        self.init(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(alpha))
    }
    public var premultiplied: [UInt8] {
        [red, green, blue].map { UInt8((Double($0) * Double(alpha) / 255).rounded()) } + [alpha]
    }
    public static let black = EditorColor(red: 0, green: 0, blue: 0)
    public static let white = EditorColor(red: 255, green: 255, blue: 255)

    /// Samples the canonical raster, never the checkerboard or display interpolation.
    public static func sample(_ raster: RasterSurface, at point: CGPoint) -> EditorColor? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
            point.x < Double(raster.size.width), point.y < Double(raster.size.height)
        else { return nil }
        let offset = (Int(point.y) * raster.size.width + Int(point.x)) * 4
        let bytes = raster.rgbaBytes
        let alpha = bytes[offset + 3]
        guard alpha > 0 else { return EditorColor(red: 0, green: 0, blue: 0, alpha: 0) }
        func straight(_ channel: Int) -> UInt8 {
            UInt8(min(255, (Double(bytes[offset + channel]) * 255 / Double(alpha)).rounded()))
        }
        return EditorColor(red: straight(0), green: straight(1), blue: straight(2), alpha: alpha)
    }
}

public struct StrokeSettings: Sendable {
    public static let diameterRange = 1...512
    public let tool: PaintTool
    public let diameter: Int
    public let color: EditorColor
    public init(tool: PaintTool, diameter: Int, color: EditorColor) {
        self.tool = tool
        self.diameter = min(Self.diameterRange.upperBound, max(Self.diameterRange.lowerBound, diameter))
        self.color = color
    }
}

public enum PaintingError: LocalizedError {
    case unavailableLayer, staleStroke, samplingTool
    public var errorDescription: String? {
        switch self {
        case .unavailableLayer: "Show the selected layer and raise its opacity above zero to paint."
        case .staleStroke: "The document or selected layer changed. The unfinished stroke was cancelled."
        case .samplingTool: "Use the Eyedropper to sample a color."
        }
    }
}

/// A display-only replacement for a small rectangular part of the cached composite.
public struct StrokePreview {
    public let rect: CGRect
    public let raster: RasterSurface
}

/// Single-owner transaction, independent of UI events. The document stays immutable until finish.
/// Maximum coverage is applied against the starting pixels, so overlapping stamps do not darken
/// a translucent stroke. A second stroke can build up opacity normally.
public final class PixelStroke {
    public let documentID: UUID
    public let layerID: UUID
    public let settings: StrokeSettings
    private let revision: UUID
    private let source: ImageDocument
    private let original: Data
    private var working: Data
    private var coverage: [UInt8]
    private var lastPoint: CGPoint?
    private var distanceToNext = 0.0
    private var dirtyPatches = Set<Int>()
    private let patchSize = 128
    public private(set) var stampCount = 0
    public private(set) var previewPixelCount = 0
    public private(set) var previews: [Int: StrokePreview] = [:]
    private var columns: Int { (source.size.width + patchSize - 1) / patchSize }

    public init(document: ImageDocument, settings: StrokeSettings) throws {
        guard settings.tool != .eyedropper else { throw PaintingError.samplingTool }
        guard document.activeLayer.isVisible, document.activeLayer.opacity > 0 else {
            throw PaintingError.unavailableLayer
        }
        self.documentID = document.id
        self.layerID = document.activeLayerID
        self.revision = document.renderRevision
        self.source = document
        self.settings = settings
        self.original = document.activeLayer.raster.rgbaBytes
        self.working = original
        self.coverage = [UInt8](repeating: 0, count: document.size.width * document.size.height)
    }

    public func validate(_ document: ImageDocument) throws {
        guard document.id == documentID, document.renderRevision == revision,
            document.activeLayerID == layerID,
            document.activeLayer.raster.image === source.activeLayer.raster.image
        else { throw PaintingError.staleStroke }
    }

    /// Arc-length spacing, carried across events: Pencil 0.5 px; round tools max(0.5, diameter/4).
    /// Input outside a bounded apron is clamped, preventing unbounded interpolation work.
    public func append(_ input: CGPoint) {
        guard input.x.isFinite, input.y.isFinite else { return }
        let apron = Double(settings.diameter)
        let point = CGPoint(
            x: min(Double(source.size.width) + apron, max(-apron, input.x)),
            y: min(Double(source.size.height) + apron, max(-apron, input.y)))
        let spacing = settings.tool == .pencil ? 0.5 : max(0.5, Double(settings.diameter) / 4)
        guard let previous = lastPoint else {
            stamp(point)
            lastPoint = point
            distanceToNext = spacing
            return
        }
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        var distance = distanceToNext
        while distance <= length {
            stamp(CGPoint(x: previous.x + dx * distance / length, y: previous.y + dy * distance / length))
            distance += spacing
        }
        distanceToNext = distance - length
        lastPoint = point
    }

    /// Includes the endpoint once. No-op transactions do not create history or dirty state.
    public func finish(in document: ImageDocument) throws -> RasterSurface? {
        try validate(document)
        if let lastPoint { stamp(lastPoint) }
        guard working != original else { return nil }
        return try RasterSurface(size: source.size, premultipliedRGBA: working)
    }

    /// Assemble the final cached display image from exact preview replacements. The caller must
    /// supply the unchanged composite captured with this stroke; validation precedes document commit.
    public func compositedPreview(over base: RasterSurface) throws -> RasterSurface {
        guard base.size == source.size else { throw LayerError.invalidRaster }
        try refreshPreview()
        // The base also belongs to the document and its undo snapshots. Allocate owned
        // writable storage instead of mutating Data bridged from its CGImage provider.
        var bytes = base.rgbaBytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        bytes.withUnsafeMutableBytes { destination in
            for preview in previews.values {
                preview.raster.rgbaBytes.withUnsafeBytes { input in
                    for row in 0..<preview.raster.size.height {
                        let offset = ((Int(preview.rect.minY) + row) * source.size.width + Int(preview.rect.minX)) * 4
                        let rowBytes = preview.raster.size.width * 4
                        destination.baseAddress!.advanced(by: offset).copyMemory(
                            from: input.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
                    }
                }
            }
        }
        return try RasterSurface(size: source.size, premultipliedRGBA: bytes)
    }

    private func stamp(_ point: CGPoint) {
        stampCount += 1
        let radius = Double(settings.diameter) / 2
        let pencil = settings.tool == .pencil
        // Pixel-aligned square Pencil, including an unambiguous one-pixel mark at floor(input).
        let center = pencil ? CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5) : point
        let minX = max(0, Int(floor(center.x - radius - 0.5)))
        let minY = max(0, Int(floor(center.y - radius - 0.5)))
        let maxX = min(source.size.width, Int(ceil(center.x + radius + 0.5)))
        let maxY = min(source.size.height, Int(ceil(center.y + radius + 0.5)))
        guard minX < maxX, minY < maxY else { return }
        let color = settings.color.premultiplied
        let pencilX = Int(floor(point.x)) - settings.diameter / 2
        let pencilY = Int(floor(point.y)) - settings.diameter / 2
        working.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            original.withUnsafeBytes { originalRaw in
                let before = originalRaw.bindMemory(to: UInt8.self)
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        let amount: UInt8
                        if pencil {
                            amount =
                                (x >= pencilX && x < pencilX + settings.diameter
                                    && y >= pencilY && y < pencilY + settings.diameter) ? 255 : 0
                        } else {
                            let distance = hypot(Double(x) + 0.5 - center.x, Double(y) + 0.5 - center.y)
                            amount = UInt8((min(1, max(0, radius + 0.5 - distance)) * 255).rounded())
                        }
                        let index = y * source.size.width + x
                        guard amount > coverage[index] else { continue }
                        coverage[index] = amount
                        let offset = index * 4
                        let strength = Double(amount) / 255
                        var changed = false
                        for channel in 0..<4 {
                            let value: UInt8
                            switch settings.tool {
                            case .pencil: value = color[channel]
                            case .eraser:
                                value = UInt8((Double(before[offset + channel]) * (1 - strength)).rounded())
                            case .brush:
                                let remaining = 1 - Double(color[3]) / 255 * strength
                                value = UInt8(
                                    min(
                                        255,
                                        (Double(color[channel]) * strength
                                            + Double(before[offset + channel]) * remaining).rounded()))
                            case .eyedropper: return
                            }
                            changed = changed || pixels[offset + channel] != value
                            pixels[offset + channel] = value
                        }
                        if changed { dirtyPatches.insert((y / patchSize) * columns + x / patchSize) }
                    }
                }
            }
        }
    }

    /// Only changed 128px patches are composited. This cache lives for one gesture, not in the file.
    @discardableResult
    public func refreshPreview() throws -> [StrokePreview] {
        var updated: [StrokePreview] = []
        for key in dirtyPatches.sorted() {
            let x = key % columns * patchSize
            let y = key / columns * patchSize
            let width = min(patchSize, source.size.width - x)
            let height = min(patchSize, source.size.height - y)
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let raster = try LayerCompositor.compositeRegion(source, rect: rect, replacing: layerID, bytes: working)
            let preview = StrokePreview(rect: rect, raster: raster)
            previews[key] = preview
            updated.append(preview)
            previewPixelCount += width * height
        }
        dirtyPatches.removeAll(keepingCapacity: true)
        return updated
    }
}

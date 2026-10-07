import Foundation

public enum LayerError: LocalizedError, Equatable {
    case invalidLayer, invalidOpacity, invalidName, lastLayer, invalidIndex, invalidRaster, layerLimit, mergePrecision

    public var errorDescription: String? {
        switch self {
        case .invalidLayer: "The document has missing, duplicate, or mismatched layers."
        case .invalidOpacity: "Layer opacity must be between 0 and 100 percent."
        case .invalidName: "Enter a layer name of 1–255 characters without control characters."
        case .lastLayer: "Keep at least one layer in the document."
        case .invalidIndex: "That position is outside the layer stack."
        case .invalidRaster: "The layer pixels are incomplete or are not valid premultiplied RGBA."
        case .layerLimit: "This document has reached the layer memory limit (128 layers or 128 million layer pixels)."
        case .mergePrecision:
            "Merge Down currently supports the bottom two layers, preserving exact 8-bit appearance. Move to the second layer from the bottom, or use Flatten Image."
        }
    }
}

public struct RasterLayer: Identifiable, Sendable {
    public let id: UUID
    public private(set) var name: String
    public let raster: RasterSurface
    public private(set) var isVisible: Bool
    public private(set) var opacity: Double

    public init(id: UUID = UUID(), name: String, raster: RasterSurface, isVisible: Bool = true, opacity: Double = 1)
        throws
    {
        self.id = id
        self.name = try Self.validatedName(name)
        guard opacity.isFinite, (0...1).contains(opacity) else { throw LayerError.invalidOpacity }
        self.raster = raster
        self.isVisible = isVisible
        self.opacity = opacity
    }

    fileprivate static func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255,
            name.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw LayerError.invalidName }
        return name
    }

    fileprivate mutating func rename(_ name: String) throws { self.name = try Self.validatedName(name) }
    fileprivate mutating func setVisible(_ visible: Bool) { isVisible = visible }
    fileprivate mutating func setOpacity(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw LayerError.invalidOpacity }
        opacity = value
    }
}

public enum LayerEdit: Sendable {
    case add
    case delete(UUID)
    case duplicate(UUID)
    case rename(UUID, String)
    case move(UUID, to: Int)
    case visibility(UUID, Bool)
    case opacity(UUID, Double)
    case mergeDown(UUID)
    case flatten

    public var actionName: String {
        switch self {
        case .add: "Add Layer"
        case .delete: "Delete Layer"
        case .duplicate: "Duplicate Layer"
        case .rename: "Rename Layer"
        case .move: "Move Layer"
        case .visibility(_, let visible): visible ? "Show Layer" : "Hide Layer"
        case .opacity: "Change Layer Opacity"
        case .mergeDown: "Merge Down"
        case .flatten: "Flatten Image"
        }
    }
}

/// Value metadata with retained immutable pixel storage. Layers are stored bottom-to-top.
/// Selection is session state; codecs intentionally omit it. Undo retains metadata and only
/// the raster buffers an operation actually needs, never a flattened image per property edit.
public struct ImageDocument: Sendable {
    public static let maximumLayers = 128
    public static let maximumLayerPixels = 128_000_000
    public let id: UUID
    public let size: PixelSize
    public private(set) var layers: [RasterLayer]
    public private(set) var activeLayerID: UUID
    public private(set) var renderRevision = UUID()
    public var activeLayer: RasterLayer { layers.first { $0.id == activeLayerID }! }
    public var activeIndex: Int { layers.firstIndex { $0.id == activeLayerID }! }
    public var canAddLayer: Bool { Self.acceptsLayerCount(layers.count + 1, size: size) }
    public var canMergeDown: Bool { activeIndex == 1 }

    public init(raster: RasterSurface) {
        // This literal is valid by construction; imported filenames use the throwing rename API.
        let layer = try! RasterLayer(name: "Background", raster: raster)
        self.id = UUID()
        self.size = raster.size
        self.layers = [layer]
        self.activeLayerID = layer.id
    }

    public init(id: UUID = UUID(), size: PixelSize, layers: [RasterLayer], activeLayerID: UUID? = nil) throws {
        guard !layers.isEmpty, Set(layers.map(\.id)).count == layers.count,
            layers.allSatisfy({ $0.raster.size == size })
        else { throw LayerError.invalidLayer }
        guard Self.acceptsLayerCount(layers.count, size: size) else { throw LayerError.layerLimit }
        let active = activeLayerID ?? layers.last!.id
        guard layers.contains(where: { $0.id == active }) else { throw LayerError.invalidLayer }
        self.id = id
        self.size = size
        self.layers = layers
        self.activeLayerID = active
    }

    public static func acceptsLayerCount(_ count: Int, size: PixelSize) -> Bool {
        count > 0 && count <= maximumLayers && count <= maximumLayerPixels / (size.width * size.height)
    }

    public mutating func selectLayer(_ id: UUID) throws {
        guard layers.contains(where: { $0.id == id }) else { throw LayerError.invalidLayer }
        activeLayerID = id
    }

    /// All edits validate before assignment. A failure or no-op leaves the entire value unchanged.
    @discardableResult
    public mutating func apply(_ edit: LayerEdit) throws -> Bool {
        var next = self
        let changesPixels: Bool
        switch edit {
        case .add:
            guard canAddLayer else { throw LayerError.layerLimit }
            let layer = try RasterLayer(
                name: "Layer \(layers.count + 1)", raster: RasterSurface(size: size, background: .transparent))
            next.layers.insert(layer, at: activeIndex + 1)
            next.activeLayerID = layer.id
            changesPixels = true
        case .delete(let id):
            let index = try index(of: id)
            guard layers.count > 1 else { throw LayerError.lastLayer }
            next.layers.remove(at: index)
            if id == activeLayerID { next.activeLayerID = next.layers[max(0, index - 1)].id }
            changesPixels = true
        case .duplicate(let id):
            let index = try index(of: id)
            guard canAddLayer else { throw LayerError.layerLimit }
            let source = layers[index]
            let layer = try RasterLayer(
                name: String(source.name.prefix(250)) + " copy", raster: source.raster,
                isVisible: source.isVisible, opacity: source.opacity)
            next.layers.insert(layer, at: index + 1)
            next.activeLayerID = layer.id
            changesPixels = true
        case .rename(let id, let name):
            let index = try index(of: id)
            try next.layers[index].rename(name)
            guard layers[index].name != next.layers[index].name else { return false }
            changesPixels = false
        case .move(let id, let destination):
            let index = try index(of: id)
            guard layers.indices.contains(destination) else { throw LayerError.invalidIndex }
            guard index != destination else { return false }
            next.layers.insert(next.layers.remove(at: index), at: destination)
            changesPixels = true
        case .visibility(let id, let visible):
            let index = try index(of: id)
            guard layers[index].isVisible != visible else { return false }
            next.layers[index].setVisible(visible)
            changesPixels = true
        case .opacity(let id, let value):
            let index = try index(of: id)
            try next.layers[index].setOpacity(value)
            guard layers[index].opacity != value else { return false }
            changesPixels = true
        case .mergeDown(let id):
            let index = try index(of: id)
            // Quantizing a middle sub-stack changes rounding against the backdrop. The bottom
            // pair is exact because it has the same transparent backdrop before and after merge.
            guard index == 1 else { throw LayerError.mergePrecision }
            let pair = try ImageDocument(size: size, layers: Array(layers.prefix(2)))
            let merged = try RasterLayer(
                id: layers[0].id, name: layers[0].name, raster: LayerCompositor.composite(pair))
            next.layers.replaceSubrange(0...1, with: [merged])
            if activeLayerID == id { next.activeLayerID = merged.id }
            changesPixels = true
        case .flatten:
            guard layers.count > 1 || !layers[0].isVisible || layers[0].opacity != 1 else { return false }
            let layer = try RasterLayer(
                id: activeLayerID, name: "Flattened Image", raster: LayerCompositor.composite(self))
            next.layers = [layer]
            changesPixels = true
        }
        if changesPixels { next.renderRevision = UUID() }
        self = next
        return true
    }

    private func index(of id: UUID) throws -> Int {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw LayerError.invalidLayer }
        return index
    }
}

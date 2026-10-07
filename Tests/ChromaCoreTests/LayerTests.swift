import CoreGraphics
import Foundation
import Testing

@testable import ChromaCore

struct LayerTests {
    @Test func blankHasOneActiveLayerAndImportRetainsStorage() throws {
        let original = try sampleDocument()
        #expect(original.layers.count == 1)
        #expect(original.activeLayerID == original.layers[0].id)
        #expect(original.activeLayer.name == "Background")
        #expect(try LayerCompositor.composite(original).image === original.layers[0].raster.image)
    }

    @Test func addInsertsAboveSelectionWithTransparentPixels() throws {
        var doc = try layeredFixture()
        try doc.selectLayer(doc.layers[0].id)
        try doc.apply(.add)
        #expect(doc.layers.count == 4)
        #expect(doc.activeIndex == 1)
        #expect(doc.activeLayer.raster.rgbaBytes.allSatisfy { $0 == 0 })
        #expect(doc.activeLayer.raster.size == doc.size)
    }

    @Test(arguments: [0, 1, 2]) func deletingActiveLayerSelectsBelowOrNext(index: Int) throws {
        var doc = try layeredFixture()
        let expected = doc.layers[index == 0 ? 1 : index - 1].id
        try doc.selectLayer(doc.layers[index].id)
        try doc.apply(.delete(doc.activeLayerID))
        #expect(doc.activeLayerID == expected)
        #expect(doc.layers.count == 2)
    }

    @Test func deleteOtherLayerPreservesSelectionAndLastLayerIsProtected() throws {
        var doc = try layeredFixture()
        let active = doc.activeLayerID
        try doc.apply(.delete(doc.layers[0].id))
        #expect(doc.activeLayerID == active)
        try doc.apply(.delete(doc.layers[0].id))
        #expect(throws: LayerError.lastLayer) { try doc.apply(.delete(active)) }
        #expect(doc.layers.count == 1)
    }

    @Test func duplicateSharesOnlyImmutableStorage() throws {
        var doc = try layeredFixture()
        let original = doc.activeLayer
        try doc.apply(.duplicate(original.id))
        let copy = doc.activeLayer
        #expect(copy.id != original.id)
        #expect(copy.raster.image === original.raster.image)
        try doc.apply(.rename(copy.id, "Copy"))
        try doc.apply(.opacity(copy.id, 0.2))
        try doc.apply(.visibility(copy.id, false))
        #expect(doc.layers[2].name == original.name)
        #expect(doc.layers[2].opacity == original.opacity)
        #expect(doc.layers[2].isVisible == original.isVisible)
        var bytes = copy.raster.rgbaBytes
        bytes[0] = 0
        #expect(original.raster.rgbaBytes[0] == 64)
    }

    @Test func renameTrimsAndPreservesRenderRevision() throws {
        var doc = try layeredFixture()
        let id = doc.activeLayerID
        let revision = doc.renderRevision
        try doc.apply(.rename(id, "  Highlights  "))
        #expect(doc.activeLayer.name == "Highlights")
        #expect(doc.activeLayerID == id)
        #expect(doc.renderRevision == revision)
        #expect(try !doc.apply(.rename(id, "Highlights")))
    }

    @Test(arguments: ["", "   ", "bad\nname", String(repeating: "x", count: 256)])
    func invalidNamesAreTransactional(name: String) throws {
        var doc = try layeredFixture()
        let before = doc.activeLayer.name
        #expect(throws: LayerError.invalidName) { try doc.apply(.rename(doc.activeLayerID, name)) }
        #expect(doc.activeLayer.name == before)
    }

    @Test func reorderUsesFinalBottomToTopIndicesAndPreservesIdentity() throws {
        var doc = try layeredFixture()
        let ids = doc.layers.map(\.id)
        try doc.apply(.move(ids[2], to: 0))
        #expect(doc.layers.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(doc.activeLayerID == ids[2])
        #expect(throws: LayerError.invalidIndex) { try doc.apply(.move(ids[2], to: 3)) }
        #expect(throws: LayerError.invalidIndex) { try doc.apply(.move(ids[2], to: -1)) }
        #expect(try !doc.apply(.move(ids[2], to: 0)))
    }

    @Test(arguments: [-0.1, 1.1, Double.nan, Double.infinity])
    func opacityRejectsInvalidValues(value: Double) throws {
        var doc = try layeredFixture()
        #expect(throws: LayerError.invalidOpacity) { try doc.apply(.opacity(doc.activeLayerID, value)) }
        #expect(doc.activeLayer.opacity == 0.5)
    }

    @Test func opacityVisibilityAndSelectionInvalidation() throws {
        var doc = try layeredFixture()
        let revision = doc.renderRevision
        try doc.selectLayer(doc.layers[0].id)
        #expect(doc.renderRevision == revision)
        try doc.apply(.opacity(doc.activeLayerID, 0))
        #expect(doc.activeLayer.opacity == 0)
        #expect(doc.renderRevision != revision)
        try doc.apply(.opacity(doc.activeLayerID, 1))
        try doc.apply(.visibility(doc.activeLayerID, false))
        #expect(!doc.activeLayer.isVisible)
        #expect(try !doc.apply(.visibility(doc.activeLayerID, false)))
        #expect(throws: LayerError.invalidLayer) { try doc.selectLayer(UUID()) }
    }

    @Test func rejectsInvalidDocumentInvariants() throws {
        let doc = try layeredFixture()
        #expect(throws: LayerError.invalidLayer) { try ImageDocument(size: doc.size, layers: []) }
        #expect(throws: LayerError.invalidLayer) {
            try ImageDocument(size: doc.size, layers: [doc.layers[0], doc.layers[0]])
        }
        #expect(throws: LayerError.invalidLayer) {
            try ImageDocument(size: doc.size, layers: doc.layers, activeLayerID: UUID())
        }
        #expect(throws: LayerError.invalidLayer) {
            try ImageDocument(size: PixelSize(width: 2, height: 1), layers: doc.layers)
        }
        #expect(!ImageDocument.acceptsLayerCount(129, size: doc.size))
        #expect(!ImageDocument.acceptsLayerCount(5, size: try PixelSize(width: 8000, height: 4000)))
    }

    @Test func layerLimitRejectsAddAndDuplicateWithoutMutation() throws {
        let surface = try solid([0, 0, 0, 0])
        let layers = try (0..<128).map { try RasterLayer(name: "Layer \($0)", raster: surface) }
        var doc = try ImageDocument(size: surface.size, layers: layers)
        #expect(throws: LayerError.layerLimit) { try doc.apply(.add) }
        #expect(throws: LayerError.layerLimit) { try doc.apply(.duplicate(doc.activeLayerID)) }
        #expect(doc.layers.count == 128)
    }

    @Test func sourceOverHasExplicitPremultipliedResults() throws {
        let bottom = try RasterLayer(name: "Blue", raster: solid([0, 0, 255, 255]))
        let top = try RasterLayer(name: "Half red", raster: solid([128, 0, 0, 128]))
        var doc = try ImageDocument(size: bottom.raster.size, layers: [bottom, top])
        #expect(try compositeBytes(doc) == [128, 0, 127, 255])
        try doc.apply(.opacity(top.id, 0.5))
        #expect(try compositeBytes(doc) == [64, 0, 191, 255])
        try doc.apply(.move(top.id, to: 0))
        #expect(try compositeBytes(doc) == [0, 0, 255, 255])
    }

    @Test func partialAlphaOverTransparencyAndHiddenLayers() throws {
        let lower = try RasterLayer(name: "Blue", raster: solid([0, 0, 64, 64]))
        let upper = try RasterLayer(name: "Red", raster: solid([128, 0, 0, 128]))
        var doc = try ImageDocument(size: lower.raster.size, layers: [lower, upper])
        #expect(try compositeBytes(doc) == [128, 0, 32, 160])
        try doc.apply(.visibility(upper.id, false))
        #expect(try compositeBytes(doc) == [0, 0, 64, 64])
        try doc.apply(.opacity(lower.id, 0))
        #expect(try compositeBytes(doc) == [0, 0, 0, 0])
    }

    @Test func rejectsNonPremultipliedAndTruncatedPixels() throws {
        #expect(throws: LayerError.invalidRaster) { try solid([255, 0, 0, 0]) }
        #expect(throws: LayerError.invalidRaster) { try solid([0, 0, 0]) }
    }

    @Test(arguments: [true, false]) func mergeBottomPairPreservesExactCompleteAppearance(visible: Bool) throws {
        var doc = try layeredFixture()
        let bottomID = doc.layers[0].id
        try doc.apply(.visibility(doc.layers[1].id, visible))
        try doc.selectLayer(doc.layers[1].id)
        let before = try compositeBytes(doc)
        try doc.apply(.mergeDown(doc.activeLayerID))
        #expect(doc.layers.count == 2)
        #expect(doc.activeLayerID == bottomID)
        #expect(try compositeBytes(doc) == before)
        #expect(doc.activeLayer.isVisible && doc.activeLayer.opacity == 1)
    }

    @Test func arbitraryMiddleMergeIsRejectedToAvoidRoundingChanges() throws {
        var doc = try layeredFixture()
        #expect(throws: LayerError.mergePrecision) { try doc.apply(.mergeDown(doc.activeLayerID)) }
        #expect(doc.layers.count == 3)
    }

    @Test func flattenPreservesRenderedAlphaAndIdentity() throws {
        var doc = try layeredFixture()
        try doc.apply(.visibility(doc.layers[1].id, false))
        let before = try compositeBytes(doc)
        let id = doc.activeLayerID
        try doc.apply(.flatten)
        #expect(doc.layers.count == 1)
        #expect(doc.activeLayerID == id)
        #expect(try compositeBytes(doc) == before)
        #expect(before[3] < 255)
        #expect(try !doc.apply(.flatten))
    }

    @Test func layeredPNGAndJPEGExportUseCompositeWithoutMutatingLayers() throws {
        let transparent = try RasterLayer(name: "Transparent", raster: solid([0, 0, 0, 0]))
        let red = try RasterLayer(name: "Red", raster: solid([255, 0, 0, 255]), opacity: 0.5)
        let hidden = try RasterLayer(name: "Hidden blue", raster: solid([0, 0, 255, 255]), isVisible: false)
        let doc = try ImageDocument(size: transparent.raster.size, layers: [transparent, red, hidden])
        let png = try ImageCodec.decode(data: ImageCodec.encode(doc, format: .png))
        #expect(try compositeBytes(png) == [128, 0, 0, 128])
        let jpeg = try ImageCodec.decode(data: ImageCodec.encode(doc, format: .jpeg))
        let actual = try compositeBytes(jpeg)
        let expected = [255, 127, 127, 255]
        #expect(zip(actual, expected).allSatisfy { abs(Int($0) - $1) <= 3 })
        #expect(doc.layers.count == 3)
        #expect(doc.layers[1].opacity == 0.5)
        #expect(!doc.layers[2].isVisible)
    }
}

func solid(_ bytes: [UInt8]) throws -> RasterSurface {
    try RasterSurface(size: PixelSize(width: 1, height: 1), premultipliedRGBA: Data(bytes))
}

func layeredFixture() throws -> ImageDocument {
    let layers = try [
        RasterLayer(name: "Base", raster: solid([0, 0, 64, 64]), opacity: 0.75),
        RasterLayer(name: "Middle", raster: solid([128, 0, 0, 128]), opacity: 0.25),
        RasterLayer(name: "Top", raster: solid([64, 64, 0, 128]), opacity: 0.5),
    ]
    return try ImageDocument(size: layers[0].raster.size, layers: layers)
}

func compositeBytes(_ document: ImageDocument) throws -> [UInt8] {
    Array(try LayerCompositor.composite(document).rgbaBytes)
}

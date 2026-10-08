import ChromaCore
import CoreGraphics
import Foundation
import Testing

struct PaintingTests {
    private let halfRed = EditorColor(red: 255, green: 0, blue: 0, alpha: 128)

    @Test func colorClampsConvertsAndPremultiplies() {
        let color = EditorColor(sRGBRed: 1.2, green: -1, blue: 0.5, alpha: 0.5)
        #expect(color == EditorColor(red: 255, green: 0, blue: 128, alpha: 128))
        #expect(color.premultiplied == [128, 0, 64, 128])
        #expect(EditorColor(sRGBRed: .nan, green: .infinity, blue: 0, alpha: 1).premultiplied == [0, 0, 0, 255])
    }

    @Test(arguments: [1.0, 2.0], [0.01, 0.5, 1.0, 8.0, 32.0])
    func coordinatesRoundTripWithPanAndBackingScale(backing: Double, zoom: Double) throws {
        let size = try PixelSize(width: 101, height: 77)
        let bounds = CGSize(width: 713, height: 511)
        var viewport = Viewport()
        viewport.setZoom(zoom)
        viewport.move(by: CGSize(width: 31.25, height: -42.75))
        let rect = viewport.canvasRect(
            fromDocument: CGRect(x: 12, y: 23, width: 10, height: 10), image: size, viewport: bounds,
            backingScale: backing)
        let point = viewport.documentPoint(
            fromCanvas: CGPoint(x: rect.minX, y: rect.maxY), image: size, viewport: bounds, backingScale: backing)
        #expect(abs(point.x - 12) < 0.0001 && abs(point.y - 23) < 0.0001)
        #expect(abs(rect.width - 10 * zoom / backing) < 0.0001)
    }

    @Test func fitCoordinatesUseAlignedImageOriginAndTopLeftRows() throws {
        let size = try PixelSize(width: 99, height: 75)
        var viewport = Viewport()
        viewport.fit(image: size, viewport: CGSize(width: 700, height: 400), backingScale: 2)
        let rect = viewport.imageRect(image: size, viewport: CGSize(width: 700, height: 400), backingScale: 2)
        let point = viewport.documentPoint(
            fromCanvas: CGPoint(x: rect.minX, y: rect.maxY), image: size, viewport: CGSize(width: 700, height: 400),
            backingScale: 2)
        #expect(point == .zero)
    }

    @Test(arguments: [1, 2, 7, 10]) func pencilHasExactSquareFootprint(diameter: Int) throws {
        let doc = try blank(32)
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: .pencil, diameter: diameter, color: halfRed))
        stroke.append(CGPoint(x: 16.9, y: 16.1))
        let bytes = try #require(try stroke.finish(in: doc)).rgbaBytes
        var count = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[offset + 3] > 0 {
                #expect(Array(bytes[offset..<offset + 4]) == [128, 0, 0, 128])
                count += 1
            }
        }
        #expect(count == diameter * diameter)
    }

    @Test func pencilDirectlyReplacesInsteadOfSourceOver() throws {
        let doc = ImageDocument(raster: try solid([0, 0, 255, 255]))
        let bytes = try paint(doc, tool: .pencil, diameter: 1, color: halfRed).rgbaBytes
        #expect(Array(bytes) == [128, 0, 0, 128])
    }

    @Test(arguments: [[UInt8](arrayLiteral: 0, 0, 0, 0), [0, 0, 255, 255], [0, 0, 128, 128]])
    func brushSourceOverExplicitAlpha(before: [UInt8]) throws {
        let doc = ImageDocument(raster: try solid(before))
        let bytes = try paint(doc, tool: .brush, diameter: 1, color: halfRed).rgbaBytes
        let expected: [UInt8] =
            before[3] == 0 ? [128, 0, 0, 128] : (before[3] == 255 ? [128, 0, 127, 255] : [128, 0, 64, 192])
        #expect(Array(bytes) == expected)
    }

    @Test func brushRoundEdgeHasExplicitCoverage() throws {
        let doc = try blank(3)
        let stroke = try PixelStroke(document: doc, settings: StrokeSettings(tool: .brush, diameter: 2, color: .white))
        stroke.append(CGPoint(x: 1.5, y: 1.5))
        let bytes = try #require(try stroke.finish(in: doc)).rgbaBytes
        #expect(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } == [22, 128, 22, 128, 255, 128, 22, 128, 22])
    }

    @Test(arguments: [[UInt8](arrayLiteral: 0, 0, 0, 0), [0, 0, 255, 255], [32, 64, 128, 128]])
    func eraserRemovesAllPremultipliedChannels(before: [UInt8]) throws {
        let doc = ImageDocument(raster: try solid(before))
        let stroke = try PixelStroke(document: doc, settings: StrokeSettings(tool: .eraser, diameter: 1, color: .black))
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        let result = try stroke.finish(in: doc)
        if before[3] == 0 {
            #expect(result == nil)
        } else {
            #expect(Array(try #require(result).rgbaBytes) == [0, 0, 0, 0])
        }
    }

    @Test func eraserEdgePreservesPremultiplication() throws {
        let size = try PixelSize(width: 3, height: 1)
        let doc = ImageDocument(
            raster: try RasterSurface(
                size: size, premultipliedRGBA: Data([32, 64, 128, 128, 32, 64, 128, 128, 32, 64, 128, 128])))
        let stroke = try PixelStroke(document: doc, settings: StrokeSettings(tool: .eraser, diameter: 2, color: .black))
        stroke.append(CGPoint(x: 1.5, y: 0.5))
        #expect(
            Array(try #require(try stroke.finish(in: doc)).rgbaBytes) == [16, 32, 64, 64, 0, 0, 0, 0, 16, 32, 64, 64])
    }

    @Test(arguments: [PaintTool.pencil, .brush, .eraser]) func sparseEventsHaveContinuousLines(tool: PaintTool) throws {
        let doc = try blank(64, background: tool == .eraser ? .white : .transparent)
        let stroke = try PixelStroke(document: doc, settings: StrokeSettings(tool: tool, diameter: 1, color: .white))
        stroke.append(CGPoint(x: 0.5, y: 20.5))
        stroke.append(CGPoint(x: 63.5, y: 20.5))
        let bytes = try #require(try stroke.finish(in: doc)).rgbaBytes
        for x in 0..<64 { #expect(bytes[(20 * 64 + x) * 4 + 3] == (tool == .eraser ? 0 : 255)) }
    }

    @Test func interpolationIsDeterministicAndTinyEventsDoNotRestamp() throws {
        let doc = try blank(32)
        let settings = StrokeSettings(tool: .brush, diameter: 8, color: halfRed)
        let first = try PixelStroke(document: doc, settings: settings)
        let second = try PixelStroke(document: doc, settings: settings)
        let points = [CGPoint(x: 0.5, y: 2.5), CGPoint(x: 15.5, y: 14.5), CGPoint(x: 30.5, y: 2.5)]
        for point in points {
            first.append(point)
            second.append(point)
        }
        #expect(try first.finish(in: doc)?.rgbaBytes == second.finish(in: doc)?.rgbaBytes)
        let tiny = try PixelStroke(document: doc, settings: settings)
        for i in 0..<100 { tiny.append(CGPoint(x: 10 + Double(i) / 1000, y: 10)) }
        #expect(tiny.stampCount == 1)
    }

    @Test func collinearEventSubdivisionPreservesSpacingAndAlpha() throws {
        let doc = try blank(64)
        let settings = StrokeSettings(tool: .brush, diameter: 8, color: halfRed)
        let sparse = try PixelStroke(document: doc, settings: settings)
        let dense = try PixelStroke(document: doc, settings: settings)
        sparse.append(CGPoint(x: 1.5, y: 10.5))
        sparse.append(CGPoint(x: 60.5, y: 10.5))
        for x in 1...60 { dense.append(CGPoint(x: Double(x) + 0.5, y: 10.5)) }
        #expect(try sparse.finish(in: doc)?.rgbaBytes == dense.finish(in: doc)?.rgbaBytes)
        #expect(try #require(try sparse.finish(in: doc)).rgbaBytes[(10 * 64 + 20) * 4 + 3] == 128)
    }

    @Test(arguments: [PaintTool.pencil, .brush, .eraser]) func largeBrushClipsAtEveryEdge(tool: PaintTool) throws {
        let doc = try blank(8, background: tool == .eraser ? .white : .transparent)
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: tool, diameter: Int.max, color: .white))
        #expect(stroke.settings.diameter == 512)
        for p in [CGPoint.zero, CGPoint(x: 8, y: 8), CGPoint(x: -10, y: 8), CGPoint(x: 8, y: -10)] { stroke.append(p) }
        let bytes = try #require(try stroke.finish(in: doc)).rgbaBytes
        #expect(bytes.count == 256)
        #expect(bytes.allSatisfy { $0 == (tool == .eraser ? 0 : 255) })
    }

    @Test func invalidAndFarOutsideInputIsBoundedAndNoOp() throws {
        let doc = try blank(8)
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: .brush, diameter: Int.min, color: .white))
        stroke.append(CGPoint(x: Double.nan, y: 0))
        stroke.append(CGPoint(x: -1e100, y: -1e100))
        #expect(stroke.settings.diameter == 1)
        #expect(try stroke.finish(in: doc) == nil)
        #expect(stroke.stampCount <= 2)
    }

    @Test func hiddenAndZeroOpacityAreRejected() throws {
        var doc = try blank(1)
        try doc.apply(.visibility(doc.activeLayerID, false))
        #expect(throws: PaintingError.self) {
            try PixelStroke(document: doc, settings: StrokeSettings(tool: .brush, diameter: 1, color: .white))
        }
        try doc.apply(.visibility(doc.activeLayerID, true))
        try doc.apply(.opacity(doc.activeLayerID, 0))
        #expect(throws: PaintingError.self) {
            try PixelStroke(document: doc, settings: StrokeSettings(tool: .brush, diameter: 1, color: .white))
        }
    }

    @Test func targetIdentityMetadataAndOtherLayersArePreserved() throws {
        var doc = try blank(1)
        try doc.apply(.add)
        try doc.apply(.opacity(doc.activeLayerID, 0.5))
        let before = doc
        let raster = try paint(doc, tool: .brush, diameter: 1, color: halfRed)
        try doc.replaceRaster(raster, for: doc.activeLayerID)
        #expect(doc.layers.map(\.id) == before.layers.map(\.id))
        #expect(doc.layers[0].raster.image === before.layers[0].raster.image)
        #expect(doc.activeLayer.name == before.activeLayer.name && doc.activeLayer.opacity == 0.5)
        #expect(before.activeLayer.raster.rgbaBytes == Data([0, 0, 0, 0]))
    }

    @Test func staleSelectionDeletionAndPixelReplacementCannotRetargetStroke() throws {
        var doc = try blank(1)
        try doc.apply(.add)
        let stroke = try PixelStroke(document: doc, settings: StrokeSettings(tool: .brush, diameter: 1, color: .white))
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        var selected = doc
        try selected.selectLayer(doc.layers[0].id)
        #expect(throws: PaintingError.self) { try stroke.finish(in: selected) }
        try doc.apply(.delete(doc.activeLayerID))
        #expect(throws: PaintingError.self) { try stroke.finish(in: doc) }
        #expect(throws: LayerError.invalidLayer) { try doc.replaceRaster(solid([0, 0, 0, 0]), for: UUID()) }
    }

    @Test func eyedropperSamplesVisibleCompositeOpacityAndTransparency() throws {
        var doc = try layeredFixture()
        try doc.apply(.visibility(doc.layers[2].id, false))
        let raster = try LayerCompositor.composite(doc)
        let sample = try #require(EditorColor.sample(raster, at: CGPoint(x: 0.9, y: 0.1)))
        #expect(sample.alpha == raster.rgbaBytes[3])
        #expect(sample == EditorColor(red: 110, green: 0, blue: 145, alpha: 74))
        #expect(EditorColor.sample(raster, at: CGPoint(x: 1, y: 0)) == nil)
        #expect(EditorColor.sample(try blank(1).activeLayer.raster, at: .zero)?.alpha == 0)
    }

    @Test func previewPatchesEqualFinalCompositeAndReuseUnchangedRegions() throws {
        var doc = try blank(260, background: .white)
        try doc.apply(.add)
        try doc.apply(.opacity(doc.activeLayerID, 0.5))
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: .brush, diameter: 10, color: halfRed))
        stroke.append(CGPoint(x: 125.5, y: 128.5))
        let base = try LayerCompositor.composite(doc)
        let patches = try stroke.refreshPreview()
        #expect(patches.count == 4)
        #expect(try stroke.refreshPreview().isEmpty)
        try doc.replaceRaster(#require(try stroke.finish(in: doc)), for: doc.activeLayerID)
        let full = try LayerCompositor.composite(doc).rgbaBytes
        #expect(try stroke.compositedPreview(over: base).rgbaBytes == full)
        for patch in patches {
            let bytes = patch.raster.rgbaBytes
            for y in 0..<patch.raster.size.height {
                let src = ((Int(patch.rect.minY) + y) * 260 + Int(patch.rect.minX)) * 4
                let dst = y * patch.raster.size.width * 4
                #expect(bytes[dst..<dst + patch.raster.size.width * 4] == full[src..<src + patch.raster.size.width * 4])
            }
        }
    }

    @Test func previewAssemblyPreservesSourceAndEarlierSnapshots() throws {
        let doc = try blank(16)
        let base = try LayerCompositor.composite(doc)
        // Independent expected bytes cannot change along with an aliased image provider.
        let transparent = Data(count: 16 * 16 * 4)
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: .pencil, diameter: 1, color: .white))
        stroke.append(CGPoint(x: 2.5, y: 3.5))
        try stroke.refreshPreview()
        #expect(doc.activeLayer.raster.rgbaBytes == transparent)
        let first = try stroke.compositedPreview(over: base)
        var expectedFirst = transparent
        expectedFirst.replaceSubrange((3 * 16 + 2) * 4..<(3 * 16 + 2) * 4 + 4, with: [255, 255, 255, 255])
        #expect(first.rgbaBytes == expectedFirst)
        #expect(base.rgbaBytes == transparent)
        #expect(doc.activeLayer.raster.rgbaBytes == transparent)

        stroke.append(CGPoint(x: 5.5, y: 3.5))
        let finished = try #require(try stroke.finish(in: doc))
        let second = try stroke.compositedPreview(over: base)
        var expectedSecond = transparent
        expectedSecond.replaceSubrange((3 * 16 + 2) * 4..<(3 * 16 + 6) * 4, with: repeatElement(UInt8(255), count: 16))
        #expect(finished.rgbaBytes == expectedSecond)
        #expect(second.rgbaBytes == expectedSecond)
        #expect(first.rgbaBytes == expectedFirst)
        #expect(base.rgbaBytes == transparent)
        #expect(doc.activeLayer.raster.rgbaBytes == transparent)
    }

    @Test func paintedNativeRoundTripAndPNGAreExactJPEGUsesWhiteMatte() throws {
        var doc = try blank(16)
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: .pencil, diameter: 32, color: halfRed))
        stroke.append(CGPoint(x: 8, y: 8))
        try doc.replaceRaster(#require(try stroke.finish(in: doc)), for: doc.activeLayerID)
        let reopened = try NativeDocumentCodec.decode(NativeDocumentCodec.fileWrapper(for: doc))
        #expect(reopened.activeLayer.raster.rgbaBytes == doc.activeLayer.raster.rgbaBytes)
        #expect(reopened.activeLayer.id == doc.activeLayerID)
        let png = try ImageCodec.decode(data: ImageCodec.encode(doc, format: .png))
        #expect(png.activeLayer.raster.rgbaBytes == doc.activeLayer.raster.rgbaBytes)
        let jpeg = try ImageCodec.decode(data: ImageCodec.encode(doc, format: .jpeg)).activeLayer.raster.rgbaBytes
        #expect(zip(jpeg.prefix(4), [255, 127, 127, 255]).allSatisfy { abs(Int($0) - $1) <= 3 })
    }

    @Test func importedJPEGLayerErasesToTransparency() throws {
        let source = try blank(8, background: .white)
        let doc = try ImageCodec.decode(data: ImageCodec.encode(source, format: .jpeg))
        let raster = try paint(doc, tool: .eraser, diameter: 1, color: .black)
        #expect(Array(raster.rgbaBytes.prefix(4)) == [0, 0, 0, 0])
        #expect(raster.rgbaBytes[7] == 255)
    }

    private func blank(_ side: Int, background: ImageBackground = .transparent) throws -> ImageDocument {
        ImageDocument(raster: try RasterSurface(size: PixelSize(width: side, height: side), background: background))
    }
    private func paint(_ doc: ImageDocument, tool: PaintTool, diameter: Int, color: EditorColor) throws -> RasterSurface
    {
        let stroke = try PixelStroke(
            document: doc, settings: StrokeSettings(tool: tool, diameter: diameter, color: color))
        stroke.append(CGPoint(x: 0.5, y: 0.5))
        return try #require(try stroke.finish(in: doc))
    }
}

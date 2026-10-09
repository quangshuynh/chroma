import ChromaCore
import CoreGraphics
import Foundation
import Testing

struct SelectionTests {
    @Test(arguments: [false, true], [false, true])
    func rectangleEveryDirection(reverseX: Bool, reverseY: Bool) throws {
        let size = try PixelSize(width: 8, height: 6)
        let mask = SelectionMask.drag(
            from: CGPoint(x: reverseX ? 6.9 : 1.9, y: reverseY ? 5.1 : 2.1),
            to: CGPoint(x: reverseX ? 1.9 : 6.9, y: reverseY ? 2.1 : 5.1), shape: .rectangle, size: size)
        #expect(mask.bounds == CGRect(x: 1, y: 2, width: 5, height: 3))
        #expect(mask.spans(at: 2) == [1..<6])
        #expect(!mask.contains(x: 6, y: 3) && !mask.contains(x: 1, y: 5))
    }

    @Test func geometryClipsAndRejectsInvalidCoordinates() throws {
        let size = try PixelSize(width: 5, height: 5)
        let mask = SelectionMask.drag(
            from: CGPoint(x: -1e100, y: -3), to: CGPoint(x: 1e100, y: 4.9), shape: .rectangle, size: size)
        #expect(mask.bounds == CGRect(x: 0, y: 0, width: 5, height: 4))
        #expect(SelectionMask.drag(from: .zero, to: .zero, shape: .rectangle, size: size).bounds == nil)
        #expect(
            SelectionMask.drag(from: CGPoint(x: Double.nan, y: 0), to: .zero, shape: .ellipse, size: size).bounds == nil
        )
        #expect(SelectionMask.rectangle(.infinite, size: size).bounds == nil)
        #expect(SelectionMask.rectangle(CGRect(x: 8, y: 8, width: 2, height: 2), size: size).bounds == nil)
    }

    @Test func ellipseHasDeterministicBinaryPixelCentersAndClipsWithoutReshaping() throws {
        let size = try PixelSize(width: 5, height: 5)
        let ellipse = SelectionMask.ellipse(CGRect(x: 0, y: 0, width: 5, height: 5), size: size)
        #expect((0..<5).map { ellipse.spans(at: $0) } == [[1..<4], [0..<5], [0..<5], [0..<5], [1..<4]])
        let clipped = SelectionMask.ellipse(CGRect(x: -2, y: 0, width: 5, height: 5), size: size)
        #expect((0..<5).map { clipped.spans(at: $0) } == [[0..<2], [0..<3], [0..<3], [0..<3], [0..<2]])
        #expect(
            SelectionMask.drag(from: CGPoint(x: -2, y: 0), to: CGPoint(x: 3, y: 5), shape: .ellipse, size: size)
                == clipped)
        let boundary = SelectionMask.ellipse(CGRect(x: 0.5, y: 0.5, width: 4, height: 4), size: size)
        #expect(boundary.spans(at: 0) == [2..<3] && boundary.spans(at: 4) == [2..<3])
        #expect(!ellipse.outline().isEmpty)
    }

    @Test func inversionAllEmptyAndTranslation() throws {
        let size = try PixelSize(width: 5, height: 3)
        let rect = SelectionMask.rectangle(CGRect(x: 1, y: 1, width: 3, height: 1), size: size)
        #expect(rect.inverted().spans(at: 1) == [0..<1, 4..<5])
        #expect(rect.inverted().inverted() == rect)
        #expect(SelectionMask.all(size: size).inverted() == .empty(size: size))
        #expect(SelectionMask.empty(size: size).inverted() == .all(size: size))
        #expect(rect.translated(dx: -2, dy: -1).bounds == CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(rect.translated(dx: Int.min, dy: Int.max).bounds == nil)
    }

    @Test(arguments: [PaintTool.pencil, .brush, .eraser], [false, true])
    func paintingUsesSameMutationBoundary(tool: PaintTool, ellipse: Bool) throws {
        let size = try PixelSize(width: 7, height: 7)
        let pixel: [UInt8] = [16, 32, 64, 128]
        let raster = try RasterSurface(
            size: size, premultipliedRGBA: Data(Array(repeating: pixel, count: 49).flatMap { $0 }))
        let doc = ImageDocument(raster: raster)
        let rect = CGRect(x: 1, y: 1, width: 5, height: 5)
        let mask = ellipse ? SelectionMask.ellipse(rect, size: size) : SelectionMask.rectangle(rect, size: size)
        let settings = StrokeSettings(
            tool: tool, diameter: 32, color: EditorColor(red: 255, green: 0, blue: 0, alpha: 128))
        let stroke = try PixelStroke(document: doc, settings: settings, selection: mask)
        stroke.append(CGPoint(x: 2.5, y: 2.5))
        let bytes = try #require(try stroke.finish(in: doc)).rgbaBytes
        let expected: [UInt8] =
            tool == .pencil ? [128, 0, 0, 128] : tool == .brush ? [136, 16, 32, 192] : [0, 0, 0, 0]
        for y in 0..<7 {
            for x in 0..<7 {
                let offset = (y * 7 + x) * 4
                #expect(Array(bytes[offset..<offset + 4]) == (mask.contains(x: x, y: y) ? expected : pixel))
            }
        }
        #expect(try stroke.compositedPreview(over: raster).rgbaBytes == bytes)
        #expect(raster.rgbaBytes == Data(Array(repeating: pixel, count: 49).flatMap { $0 }))
    }

    @Test(arguments: [PaintTool.pencil, .brush, .eraser])
    func emptySelectionIsNotUnrestrictedAndTransparentSelectionIsSafe(tool: PaintTool) throws {
        let size = try PixelSize(width: 5, height: 5)
        let doc = ImageDocument(raster: try RasterSurface(size: size, background: .transparent))
        let settings = StrokeSettings(tool: tool, diameter: 32, color: .white)
        let empty = try PixelStroke(document: doc, settings: settings, selection: .empty(size: size))
        empty.append(CGPoint(x: 2, y: 2))
        #expect(try empty.finish(in: doc) == nil)
        let ellipse = SelectionMask.ellipse(CGRect(x: 0, y: 0, width: 5, height: 5), size: size)
        let stroke = try PixelStroke(document: doc, settings: settings, selection: ellipse)
        stroke.append(CGPoint(x: 2, y: 2))
        let result = try stroke.finish(in: doc)
        if tool == .eraser {
            #expect(result == nil)
        } else {
            let bytes = try #require(result).rgbaBytes
            for y in 0..<5 {
                for x in 0..<5 {
                    #expect(bytes[(y * 5 + x) * 4 + 3] == (ellipse.contains(x: x, y: y) ? 255 : 0))
                }
            }
        }
    }

    @Test func copyAndDeletePreserveAlphaAndOutsidePixels() throws {
        let doc = try fixture()
        let mask = SelectionMask.rectangle(CGRect(x: 0, y: 0, width: 2, height: 1), size: doc.size)
        #expect(
            try RegionEditing.copy(doc.activeLayer.raster, selection: mask)?.rgbaBytes
                == Data([128, 0, 0, 128, 0, 128, 0, 128]))
        #expect(
            try RegionEditing.delete(doc.activeLayer.raster, selection: mask)?.rgbaBytes
                == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0]))
        #expect(try RegionEditing.copy(doc.activeLayer.raster, selection: .empty(size: doc.size)) == nil)
        #expect(try RegionEditing.delete(doc.activeLayer.raster, selection: nil)?.rgbaBytes == Data(count: 16))
    }

    @Test func moveOverlapCompositesOnceFromStableSourceAndPreviewMatches() throws {
        var doc = try fixture()
        let original = doc.activeLayer.raster.rgbaBytes
        let mask = SelectionMask.rectangle(CGRect(x: 0, y: 0, width: 2, height: 1), size: doc.size)
        let move = try PixelMove(document: doc, selection: mask)
        try move.update(dx: 2, dy: 0)
        let retainedPreview = move.preview!.raster.rgbaBytes
        try move.update(dx: 1, dy: 0)
        let raster = try #require(try move.finish(in: doc))
        #expect(raster.rgbaBytes == Data([0, 0, 0, 0, 128, 0, 0, 128, 0, 128, 127, 255, 0, 0, 0, 0]))
        #expect(doc.activeLayer.raster.rgbaBytes == original)
        #expect(retainedPreview == Data([0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 127, 255, 0, 128, 0, 128]))
        try doc.replaceRaster(raster, for: doc.activeLayerID)
        #expect(move.preview!.raster.rgbaBytes == doc.activeLayer.raster.rgbaBytes.prefix(12))
        #expect(throws: PaintingError.self) { try move.finish(in: doc) }
    }

    @Test(arguments: [-20, -1, 0, 20]) func movementClipsAndReturnsToOrigin(dx: Int) throws {
        let doc = try fixture()
        let move = try PixelMove(document: doc, selection: .all(size: doc.size))
        try move.update(dx: dx, dy: 0)
        if dx == 0 {
            #expect(try move.finish(in: doc) == nil)
        } else if abs(dx) > 4 {
            #expect(try move.finish(in: doc)?.rgbaBytes == Data(count: 16))
        } else {
            #expect(
                try move.finish(in: doc)?.rgbaBytes == Data([0, 128, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
        try move.update(dx: 0, dy: 0)
        #expect(move.preview == nil && move.movedSelection == .all(size: doc.size))
        #expect(try move.finish(in: doc) == nil)
    }

    @Test func regionalMoveRespectsStackOpacityAndHiddenLayers() throws {
        var doc = try fixture()
        try doc.apply(.duplicate(doc.activeLayerID))
        try doc.apply(.opacity(doc.activeLayerID, 0.5))
        let move = try PixelMove(
            document: doc, selection: .rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), size: doc.size))
        try move.update(dx: 1, dy: 0)
        let preview = try #require(move.preview)
        try doc.replaceRaster(#require(try move.finish(in: doc)), for: doc.activeLayerID)
        let full = try LayerCompositor.composite(doc)
        #expect(preview.rect == CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(preview.raster.rgbaBytes == full.rgbaBytes.prefix(8))
        #expect(move.previewPixelCount == 2)
    }

    @Test func cropAcrossLayersRetainsMetadataAndPasteClips() throws {
        var doc = try fixture()
        try doc.apply(.duplicate(doc.activeLayerID))
        try doc.apply(.visibility(doc.layers[0].id, false))
        try doc.apply(.opacity(doc.activeLayerID, 0.3))
        let mask = SelectionMask.ellipse(CGRect(x: 1, y: 0, width: 2, height: 1), size: doc.size)
        let cropped = try #require(try RegionEditing.crop(doc, selection: mask))
        #expect(cropped.size == (try PixelSize(width: 2, height: 1)))
        #expect(cropped.id == doc.id && cropped.layers.map(\.id) == doc.layers.map(\.id))
        #expect(
            cropped.activeLayerID == doc.activeLayerID && cropped.activeLayer.opacity == 0.3
                && !cropped.layers[0].isVisible)
        #expect(cropped.layers.allSatisfy { $0.raster.rgbaBytes == Data([0, 128, 0, 128, 0, 0, 255, 255]) })
        let pasted = try RegionEditing.paste(doc.activeLayer.raster, into: cropped)
        #expect(pasted.layers.count == 3 && pasted.activeIndex == 2)
        #expect(pasted.activeLayer.raster.rgbaBytes == doc.activeLayer.raster.rgbaBytes.prefix(8))
        #expect(try RegionEditing.crop(doc, selection: .all(size: doc.size)) == nil)
    }

    @Test func regionEditsRoundTripNativeAndExportsUseCommittedPixels() throws {
        var doc = try fixture()
        let move = try PixelMove(document: doc, selection: .all(size: doc.size))
        try move.update(dx: 1, dy: 0)
        try doc.replaceRaster(#require(try move.finish(in: doc)), for: doc.activeLayerID)
        let cropped = try #require(
            try RegionEditing.crop(doc, selection: .rectangle(CGRect(x: 0, y: 0, width: 3, height: 1), size: doc.size)))
        let pasted = try RegionEditing.paste(cropped.activeLayer.raster, into: cropped)
        let reopened = try NativeDocumentCodec.decode(NativeDocumentCodec.fileWrapper(for: pasted))
        #expect(reopened.size == pasted.size && reopened.id == pasted.id)
        #expect(reopened.layers.map(\.id) == pasted.layers.map(\.id))
        #expect(reopened.layers.map { $0.raster.rgbaBytes } == pasted.layers.map { $0.raster.rgbaBytes })
        let png = try ImageCodec.decode(data: ImageCodec.encode(pasted, format: .png))
        #expect(png.activeLayer.raster.rgbaBytes == (try LayerCompositor.composite(pasted)).rgbaBytes)
        let jpeg = try ImageCodec.decode(data: ImageCodec.encode(pasted, format: .jpeg))
        #expect(jpeg.size == pasted.size)
        #expect(
            stride(from: 3, to: jpeg.activeLayer.raster.rgbaBytes.count, by: 4).allSatisfy {
                jpeg.activeLayer.raster.rgbaBytes[$0] == 255
            })
    }

    @Test func invertedEllipseMoveMatchesExplicitClearThenSourceOverInTwoDimensions() throws {
        let size = try PixelSize(width: 5, height: 5)
        let pixel: [UInt8] = [32, 64, 128, 128]
        let original = Data(Array(repeating: pixel, count: 25).flatMap { $0 })
        let doc = ImageDocument(raster: try RasterSurface(size: size, premultipliedRGBA: original))
        let mask = SelectionMask.ellipse(CGRect(x: 0, y: 0, width: 5, height: 5), size: size).inverted()
        // Only four corner pixels are selected by this inverted ellipse.
        let move = try PixelMove(document: doc, selection: mask)
        try move.update(dx: 1, dy: -1)
        let result = try #require(try move.finish(in: doc)).rgbaBytes
        var expected = original
        for offset in [0, 4, 20, 24] { expected.replaceSubrange(offset * 4..<offset * 4 + 4, with: [0, 0, 0, 0]) }
        // Bottom-left moves to (1, 3), other selected corners leave the canvas.
        expected.replaceSubrange(64..<68, with: [48, 96, 192, 192])
        #expect(result == expected)
        #expect(move.movedSelection.bounds == CGRect(x: 1, y: 3, width: 1, height: 1))
        #expect(doc.activeLayer.raster.rgbaBytes == original)
    }

    @Test func movementRejectsUnavailableLayersAndTransparentMovesDoNotCreatePixels() throws {
        let size = try PixelSize(width: 4, height: 4)
        var doc = ImageDocument(raster: try RasterSurface(size: size, background: .transparent))
        let move = try PixelMove(document: doc, selection: .all(size: size))
        try move.update(dx: 2, dy: -2)
        #expect(try move.finish(in: doc) == nil)
        try doc.apply(.visibility(doc.activeLayerID, false))
        #expect(throws: PaintingError.self) { try PixelMove(document: doc, selection: .all(size: size)) }
        try doc.apply(.visibility(doc.activeLayerID, true))
        try doc.apply(.opacity(doc.activeLayerID, 0))
        #expect(throws: PaintingError.self) { try PixelMove(document: doc, selection: .all(size: size)) }
        #expect(throws: LayerError.self) { try PixelMove(document: doc, selection: .empty(size: size)) }
    }

    private func fixture() throws -> ImageDocument {
        ImageDocument(
            raster: try RasterSurface(
                size: PixelSize(width: 4, height: 1),
                premultipliedRGBA: Data([128, 0, 0, 128, 0, 128, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0])))
    }
}

import AppKit
import ChromaCore
import Testing

@testable import ChromaApp

@MainActor
@Suite(.serialized)
struct SelectionDocumentTests {
    init() { _ = NSApplication.shared }

    @Test func selectionsAndCopyAreCleanAndReuseComposite() throws {
        let doc = try document()
        defer { doc.close() }
        let image = doc.rendered!.image
        let revision = doc.content!.renderRevision
        let canvas = try canvas(doc)
        canvas.selectAll(nil)
        #expect(doc.selection == .all(size: doc.content!.size))
        canvas.invertSelection(nil)
        #expect(doc.selection?.bounds == nil)
        canvas.deselect(nil)
        #expect(doc.selection == nil)
        canvas.invertSelection(nil)
        #expect(doc.selection == .all(size: doc.content!.size))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(try doc.copyPixels(to: board))
        #expect(doc.rendered!.image === image && doc.content!.renderRevision == revision)
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        #expect(
            (canvas.accessibilityValue() as? String)?.contains("Selection: 8 × 8 px at 0, 0") == true)
    }

    @Test func deleteNoSelectionEmptyAndUndoRedo() throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        let before = doc.content!.activeLayer.raster.rgbaBytes
        doc.setSelection(.empty(size: doc.content!.size))
        try doc.deletePixels()
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        doc.setSelection(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2), size: doc.content!.size))
        try doc.deletePixels()
        let deleted = doc.content!.activeLayer.raster.rgbaBytes
        #expect(deleted != before && doc.isDocumentEdited)
        #expect(deleted[(1 * 8 + 1) * 4 + 3] == 0 && deleted[3] == 255)
        #expect(canvas.displayedRaster.rgbaBytes == deleted)
        doc.undoManager?.undo()
        #expect(!doc.isDocumentEdited && doc.content!.activeLayer.raster.rgbaBytes == before)
        #expect(canvas.displayedRaster.rgbaBytes == before)
        doc.undoManager?.redo()
        #expect(canvas.displayedRaster.rgbaBytes == deleted)
        doc.setSelection(nil)
        try doc.deletePixels()
        #expect(doc.content!.activeLayer.raster.rgbaBytes == Data(count: 256))
        doc.updateChangeCount(.changeCleared)
        let action = doc.undoManager?.undoActionName
        try doc.deletePixels()
        #expect(!doc.isDocumentEdited && doc.undoManager?.undoActionName == action)
    }

    @Test func moveIsOneExactUndoStepAndRetainedSnapshotsStayImmutable() throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        let original = doc.content!
        let before = original.activeLayer.raster.rgbaBytes
        doc.setSelection(.rectangle(CGRect(x: 0, y: 0, width: 2, height: 2), size: original.size))
        try doc.beginMove()
        for x in 1...5 { try doc.continueMove(dx: x, dy: 2) }
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == before && doc.rendered!.rgbaBytes == before)
        try doc.commitMove()
        let after = doc.content!.activeLayer.raster.rgbaBytes
        #expect(after != before && original.activeLayer.raster.rgbaBytes == before)
        #expect(doc.selection?.bounds == CGRect(x: 5, y: 2, width: 2, height: 2))
        for _ in 0..<3 {
            #expect(doc.undoManager?.undoActionName == "Move Selected Pixels")
            doc.undoManager?.undo()
            #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
            #expect(doc.rendered!.rgbaBytes == before && canvas.displayedRaster.rgbaBytes == before)
            doc.undoManager?.redo()
            #expect(doc.isDocumentEdited && doc.undoManager?.canRedo == false)
            #expect(doc.rendered!.rgbaBytes == after && canvas.displayedRaster.rgbaBytes == after)
            #expect(doc.undoManager?.groupingLevel == 0)
        }
    }

    @Test func moveCancellationToolLayerUndoCloseAndNoOpAreClean() throws {
        let doc = try document()
        let canvas = try canvas(doc)
        let controller = doc.windowControllers.first as! EditorWindowController
        let before = doc.content!.activeLayer.raster.rgbaBytes
        let mask = SelectionMask.all(size: doc.content!.size)
        doc.setSelection(mask)
        try doc.beginMove()
        try doc.continueMove(dx: 2, dy: 0)
        canvas.cancelInteraction()
        #expect(doc.movement == nil && !doc.isDocumentEdited && doc.selection == mask)
        try doc.beginMove()
        try doc.continueMove(dx: 1, dy: 0)
        controller.state.tool = .ellipseSelect
        #expect(doc.movement == nil && !doc.isDocumentEdited)
        try doc.beginMove()
        try doc.continueMove(dx: 2, dy: 0)
        try doc.selectLayer(doc.content!.activeLayerID)
        #expect(doc.movement == nil && !doc.isDocumentEdited)
        try doc.beginMove()
        try doc.continueMove(dx: 1, dy: 0)
        try doc.continueMove(dx: 0, dy: 0)
        try doc.commitMove()
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        try doc.perform(.rename(doc.content!.activeLayerID, "Ink"))
        try doc.beginMove()
        try doc.continueMove(dx: 1, dy: 0)
        doc.undoManager?.undo()
        #expect(doc.movement == nil && !doc.isDocumentEdited)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == before)
        try doc.beginMove()
        try doc.continueMove(dx: 1, dy: 0)
        doc.close()
        #expect(doc.movement == nil && !doc.isDocumentEdited)
    }

    @Test func clipboardPreservesEveryLowAlphaAndExternalPNG() throws {
        var bytes = Data()
        for value in 0...255 {
            bytes.append(contentsOf: [UInt8(value / 3), UInt8(value / 2), UInt8(value), UInt8(value)])
        }
        let raster = try RasterSurface(size: PixelSize(width: 256, height: 1), premultipliedRGBA: bytes)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(try RasterClipboard.write(raster, to: board))
        #expect(RasterClipboard.canRead(board))
        #expect(try RasterClipboard.read(from: board)?.rgbaBytes == bytes)
        #expect(board.data(forType: .png) != nil)
        let png = try ImageCodec.encode(ImageDocument(raster: raster), format: .png)
        board.clearContents()
        board.setData(png, forType: .png)
        #expect(try RasterClipboard.read(from: board)?.size == raster.size)
        #expect(try RasterClipboard.read(from: board)?.rgbaBytes[3] == 0)
        board.clearContents()
        board.setData(Data(repeating: 255, count: 12), forType: RasterClipboard.canonical)
        #expect(throws: ImageError.self) { try RasterClipboard.read(from: board) }
    }

    @Test func cutPasteHaveSeparateUndoAndActiveLayerTargeting() throws {
        let doc = try document()
        defer { doc.close() }
        try doc.perform(.duplicate(doc.content!.activeLayerID))
        doc.undoManager?.removeAllActions()
        doc.updateChangeCount(.changeCleared)
        let original = doc.content!
        doc.setSelection(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2), size: original.size))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try doc.cutPixels(to: board)
        let cut = doc.content!
        #expect(cut.layers[0].raster.image === original.layers[0].raster.image)
        #expect(cut.activeLayer.raster.rgbaBytes != original.activeLayer.raster.rgbaBytes)
        try doc.pastePixels(from: board)
        let pasted = doc.content!
        #expect(pasted.layers.count == 3 && pasted.activeLayer.name == "Pasted Image")
        #expect(pasted.activeLayer.raster.rgbaBytes[3] == 255 && pasted.activeLayer.raster.rgbaBytes[11] == 0)
        doc.undoManager?.undo()
        #expect(
            doc.content!.layers.count == 2
                && doc.content!.activeLayer.raster.rgbaBytes == cut.activeLayer.raster.rgbaBytes)
        doc.undoManager?.undo()
        #expect(
            !doc.isDocumentEdited && doc.content!.activeLayer.raster.rgbaBytes == original.activeLayer.raster.rgbaBytes)
        doc.undoManager?.redo()
        doc.undoManager?.redo()
        #expect(doc.content!.activeLayerID == pasted.activeLayerID)
        #expect(doc.content!.layers.map { $0.raster.rgbaBytes } == pasted.layers.map { $0.raster.rgbaBytes })
    }

    @Test func cropUndoUpdatesCanvasSizeAndNativeSavePersistsAllRegionEdits() async throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        try doc.perform(.duplicate(doc.content!.activeLayerID))
        try doc.perform(.opacity(doc.content!.activeLayerID, 0.5))
        doc.setSelection(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2), size: doc.content!.size))
        try doc.beginMove()
        try doc.continueMove(dx: 2, dy: 2)
        try doc.commitMove()
        try doc.deletePixels()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        doc.setSelection(nil)
        #expect(try doc.copyPixels(to: board))
        try doc.pastePixels(from: board)
        let original = doc.content!
        doc.setSelection(.ellipse(CGRect(x: 1, y: 1, width: 4, height: 4), size: original.size))
        try doc.cropToSelection()
        let cropped = doc.content!
        #expect(cropped.size.width == 4 && doc.selection == nil)
        #expect(canvas.displayedRaster.size == cropped.size)
        doc.undoManager?.undo()
        #expect(doc.content!.size == original.size && canvas.displayedRaster.size == original.size)
        #expect(doc.content!.layers.map { $0.raster.rgbaBytes } == original.layers.map { $0.raster.rgbaBytes })
        doc.undoManager?.redo()
        #expect(canvas.displayedRaster.size == cropped.size)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
        defer { try? FileManager.default.removeItem(at: url) }
        try await doc.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveAsOperation)
        let reopened = try ChromaDocument(contentsOf: url, ofType: NativeDocumentCodec.type.identifier)
        defer { reopened.close() }
        #expect(!doc.isDocumentEdited && !reopened.isDocumentEdited && reopened.selection == nil)
        #expect(reopened.content!.size == cropped.size)
        #expect(reopened.content!.layers.map { $0.raster.rgbaBytes } == cropped.layers.map { $0.raster.rgbaBytes })
        #expect(reopened.content!.layers.map(\.opacity) == cropped.layers.map(\.opacity))
        doc.undoManager?.undo()
        #expect(doc.isDocumentEdited)
        doc.undoManager?.redo()
        #expect(!doc.isDocumentEdited)
    }

    @Test(arguments: [PaintTool.rectangleSelect, .ellipseSelect], [0.5, 1.0, 8.0, 32.0])
    func selectionEventsAtZoomAndMoveEscape(tool: PaintTool, zoom: Double) throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        let controller = doc.windowControllers.first as! EditorWindowController
        let window = controller.window!
        controller.state.tool = tool
        canvas.zoom(to: zoom)
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let scale = zoom / window.backingScaleFactor
        let start = CGPoint(x: center.x - 2 * scale, y: center.y + 2 * scale)
        let end = CGPoint(x: center.x + 2 * scale, y: center.y - 2 * scale)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        #expect(doc.selection == nil && !doc.isDocumentEdited)
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        let mask = try #require(doc.selection)
        #expect(mask.bounds == CGRect(x: 2, y: 2, width: 4, height: 4))
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        controller.state.tool = .moveSelected
        canvas.mouseDown(with: try event(.leftMouseDown, center))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        #expect(doc.movement != nil && !doc.isDocumentEdited)
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        #expect(doc.movement == nil && !doc.isDocumentEdited && doc.selection == mask)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == Data(repeating: 255, count: 256))
    }

    @Test func selectionPaintingAndMenuValidationRespectNativeTextEditing() throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        let controller = doc.windowControllers.first as! EditorWindowController
        let crop = NSMenuItem(title: "Crop", action: #selector(CanvasNSView.cropToSelection(_:)), keyEquivalent: "")
        #expect(!canvas.validateMenuItem(crop))
        doc.setSelection(.rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), size: doc.content!.size))
        #expect(canvas.validateMenuItem(crop))
        try doc.beginStroke(at: .zero, settings: StrokeSettings(tool: .eraser, diameter: 32, color: .black))
        try doc.commitStroke(at: CGPoint(x: 7, y: 7))
        let bytes = doc.content!.activeLayer.raster.rgbaBytes
        #expect(bytes.prefix(4) == Data(count: 4) && bytes.dropFirst(4).allSatisfy { $0 == 255 })
        doc.undoManager?.undo()
        #expect(!doc.isDocumentEdited)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        controller.window!.contentView!.addSubview(text)
        text.string = "Layer name"
        controller.window!.makeFirstResponder(text)
        text.selectAll(nil)
        #expect(text.selectedRange().length == 10)
        #expect(doc.selection?.bounds == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(!doc.isDocumentEdited)
    }

    @Test func unfinishedMoveCannotEnterNativeOrImageExportsAndSelectionCancellationRestoresMask() throws {
        let doc = try document()
        defer { doc.close() }
        let canvas = try canvas(doc)
        let original = doc.content!.activeLayer.raster.rgbaBytes
        doc.setSelection(.all(size: doc.content!.size))
        try doc.beginMove()
        try doc.continueMove(dx: 4, dy: -4)
        let native = try NativeDocumentCodec.decode(doc.fileWrapper(ofType: NativeDocumentCodec.type.identifier))
        #expect(native.activeLayer.raster.rgbaBytes == original)
        for format in [ExportFormat.png, .jpeg] {
            let decoded = try ImageCodec.decode(data: ImageCodec.encode(doc.content!, format: format))
            #expect(decoded.activeLayer.raster.rgbaBytes == original)
        }
        canvas.cancelInteraction()
        #expect(!doc.isDocumentEdited && doc.selection == .all(size: doc.content!.size))
        let controller = doc.windowControllers.first as! EditorWindowController
        controller.state.tool = .rectangleSelect
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(center, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        canvas.cancelInteraction()
        canvas.mouseUp(with: event)
        #expect(doc.selection == .all(size: doc.content!.size) && !doc.isDocumentEdited)
    }

    @Test func malformedPasteLeavesPixelsMetadataHistoryAndSelectionUnchanged() throws {
        let doc = try document()
        defer { doc.close() }
        let mask = SelectionMask.all(size: doc.content!.size)
        doc.setSelection(mask)
        let before = doc.content!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data([2, 0, 0, 0, 2, 0, 0, 0]), forType: RasterClipboard.canonical)
        #expect(throws: LayerError.self) { try doc.pastePixels(from: board) }
        #expect(doc.content!.renderRevision == before.renderRevision && doc.selection == mask)
        #expect(doc.content!.layers.map(\.id) == before.layers.map(\.id))
        #expect(doc.content!.activeLayer.raster.rgbaBytes == before.activeLayer.raster.rgbaBytes)
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
    }

    private func document() throws -> ChromaDocument {
        let doc = try ChromaDocument(
            content: ImageDocument(raster: RasterSurface(size: PixelSize(width: 8, height: 8), background: .white)))
        doc.undoManager?.groupsByEvent = false
        doc.updateChangeCount(.changeCleared)
        return doc
    }
    private func canvas(_ doc: ChromaDocument) throws -> CanvasNSView {
        doc.makeWindowControllers()
        let controller = try #require(doc.windowControllers.first as? EditorWindowController)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return try #require(controller.state.canvas)
    }
}

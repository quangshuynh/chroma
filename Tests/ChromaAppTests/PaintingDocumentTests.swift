import AppKit
import ChromaCore
import Testing

@testable import ChromaApp

@MainActor
@Suite(.serialized)
struct PaintingDocumentTests {
    init() { _ = NSApplication.shared }
    private let settings = StrokeSettings(
        tool: .brush, diameter: 3, color: EditorColor(red: 255, green: 0, blue: 0, alpha: 128))

    @Test func entireStrokeHasOneExactUndoRedoAndCleanCancellation() throws {
        let doc = try document()
        defer { doc.close() }
        let before = doc.content!.activeLayer.raster.rgbaBytes
        let transparent = Data(count: 16 * 16 * 4)
        #expect(before == transparent)
        try doc.beginStroke(at: CGPoint(x: 2.5, y: 2.5), settings: settings)
        for x in 3...12 { try doc.continueStroke(at: CGPoint(x: Double(x) + 0.5, y: 2.5)) }
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == before)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == transparent)
        try doc.commitStroke(at: CGPoint(x: 13.5, y: 2.5))
        let after = doc.content!.activeLayer.raster.rgbaBytes
        let id = doc.content!.activeLayerID
        #expect(after != before && doc.isDocumentEdited)
        #expect(doc.undoManager?.undoActionName == "Brush Stroke")
        doc.undoManager?.undo()
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == before)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == transparent)
        doc.undoManager?.redo()
        #expect(doc.content!.activeLayer.raster.rgbaBytes == after)
        #expect(doc.content?.activeLayerID == id)
        doc.updateChangeCount(.changeCleared)
        try doc.beginStroke(at: CGPoint(x: 8, y: 8), settings: settings)
        doc.cancelStroke()
        #expect(!doc.isDocumentEdited && doc.stroke == nil)
        #expect(doc.content!.activeLayer.raster.rgbaBytes == after)
    }

    @Test func repeatedStrokeAndLayerUndoRedoStaySynchronousAndSeparatelyGrouped() throws {
        let doc = try document()
        defer { doc.close() }
        let manager = try #require(doc.undoManager)
        let before = try #require(doc.rendered).rgbaBytes
        try doc.beginStroke(at: CGPoint(x: 2.5, y: 2.5), settings: settings)
        try doc.continueStroke(at: CGPoint(x: 6.5, y: 2.5))
        try doc.commitStroke(at: CGPoint(x: 12.5, y: 2.5))
        let painted = try #require(doc.rendered).rgbaBytes
        #expect(painted != before)
        let layerID = try #require(doc.content?.activeLayerID)
        let originalName = try #require(doc.content?.activeLayer.name)
        try doc.perform(.rename(layerID, "Painted"))

        for _ in 0..<5 {
            #expect(manager.groupingLevel == 0)
            #expect(manager.undoActionName == "Rename Layer")
            manager.undo()
            #expect(doc.content?.activeLayer.name == originalName)
            #expect(doc.rendered?.rgbaBytes == painted && doc.isDocumentEdited)
            #expect(manager.undoActionName == "Brush Stroke")
            manager.undo()
            #expect(doc.rendered?.rgbaBytes == before)
            #expect(doc.content?.activeLayer.raster.rgbaBytes == before)
            #expect(!doc.isDocumentEdited && !manager.canUndo)
            #expect(manager.redoActionName == "Brush Stroke")
            manager.redo()
            #expect(doc.rendered?.rgbaBytes == painted)
            #expect(doc.content?.activeLayer.raster.rgbaBytes == painted)
            #expect(doc.isDocumentEdited && manager.redoActionName == "Rename Layer")
            manager.redo()
            #expect(doc.content?.activeLayer.name == "Painted")
            #expect(doc.content?.activeLayerID == layerID)
            #expect(doc.rendered?.rgbaBytes == painted && !manager.canRedo)
            #expect(manager.groupingLevel == 0)
        }
    }

    @Test func noOpStrokeDoesNotDirtyOrRegisterUndo() throws {
        let doc = try document()
        defer { doc.close() }
        try doc.beginStroke(
            at: CGPoint(x: 2, y: 2), settings: StrokeSettings(tool: .eraser, diameter: 4, color: .black))
        try doc.commitStroke(at: CGPoint(x: 10, y: 2))
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
    }

    @Test func selectionDeletionAndUndoCancelPendingPixels() throws {
        let doc = try document()
        defer { doc.close() }
        try doc.perform(.add)
        let first = doc.content!.layers[0].id
        let second = doc.content!.activeLayerID
        doc.updateChangeCount(.changeCleared)
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        try doc.selectLayer(first)
        #expect(doc.stroke == nil && !doc.isDocumentEdited)
        try doc.commitStroke(at: CGPoint(x: 3, y: 2))
        #expect(doc.content!.layers.allSatisfy { $0.raster.rgbaBytes.allSatisfy { $0 == 0 } })
        try doc.selectLayer(second)
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        try doc.perform(.delete(second))
        #expect(doc.stroke == nil && doc.content!.activeLayerID == first)
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        doc.undoManager?.undo()
        #expect(doc.stroke == nil && doc.content!.layers.count == 2)
    }

    @Test func nativeSaveReopenKeepsPaintedBytesMetadataAndSavedUndoBoundary() async throws {
        let doc = try document()
        defer { doc.close() }
        try doc.perform(.add)
        let id = doc.content!.activeLayerID
        try doc.perform(.rename(id, "Ink"))
        try doc.perform(.opacity(id, 0.7))
        try doc.beginStroke(at: CGPoint(x: 0.5, y: 0.5), settings: settings)
        try doc.commitStroke(at: CGPoint(x: 15.5, y: 15.5))
        let before = doc.content!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
        defer { try? FileManager.default.removeItem(at: url) }
        try await doc.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveAsOperation)
        let reopened = try ChromaDocument(contentsOf: url, ofType: NativeDocumentCodec.type.identifier)
        defer { reopened.close() }
        #expect(!reopened.isDocumentEdited && !doc.isDocumentEdited)
        #expect(reopened.content!.activeLayer.raster.rgbaBytes == before.activeLayer.raster.rgbaBytes)
        #expect(reopened.content!.activeLayer.id == id && reopened.content!.activeLayer.name == "Ink")
        #expect(reopened.content!.activeLayer.opacity == 0.7)
        doc.undoManager?.undo()
        #expect(doc.isDocumentEdited)
        doc.undoManager?.redo()
        #expect(!doc.isDocumentEdited)
    }

    @Test func nativeColorConversionAndEditorChangesStayClean() throws {
        let doc = try document()
        defer { doc.close() }
        doc.makeWindowControllers()
        let controller = try #require(doc.windowControllers.first as? EditorWindowController)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let state = controller.state
        state.tool = .pencil
        state.diameter = 42
        state.foreground = try #require(EditorColor(native: NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 0.5)))
        state.background = .black
        #expect(state.foreground == EditorColor(red: 255, green: 0, blue: 128, alpha: 128))
        #expect(EditorColor(native: state.foreground.nsColor) == state.foreground)
        controller.actualSize(nil)
        state.tool = .eyedropper
        state.foreground = try #require(EditorColor.sample(doc.rendered!, at: .zero))
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        state.tool = .eraser
        #expect(doc.stroke == nil && !doc.isDocumentEdited)
    }

    @Test func canvasEventsPaintSampleHoverPanAndEscapeAtDifferentZooms() throws {
        let doc = try document()
        defer { doc.close() }
        doc.makeWindowControllers()
        let controller = try #require(doc.windowControllers.first as? EditorWindowController)
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = try #require(controller.state.canvas)
        controller.state.tool = .pencil
        controller.state.diameter = 1
        controller.state.foreground = .white
        let transparent = Data(count: 16 * 16 * 4)
        // Direct AppKit event dispatch tests actual adapter, including inverse coordinate mapping.
        func event(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        for zoom in [0.5, 1, 8] {
            canvas.zoom(to: zoom)
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            let point = canvas.documentPoint(center)
            #expect(point.x >= 0 && point.x < 16 && point.y >= 0 && point.y < 16)
            canvas.mouseMoved(with: try event(.mouseMoved, center))
            #expect(!doc.isDocumentEdited)
            canvas.mouseDown(with: try event(.leftMouseDown, center))
            canvas.mouseDragged(with: try event(.leftMouseDragged, center))
            #expect(doc.content?.activeLayer.raster.rgbaBytes == transparent)
            #expect(!doc.isDocumentEdited)
            canvas.mouseUp(with: try event(.leftMouseUp, center))
            #expect(doc.isDocumentEdited)
            let painted = try #require(doc.content?.activeLayer.raster.rgbaBytes)
            #expect(painted != transparent)
            #expect(canvas.displayedRaster.rgbaBytes == painted)
            #expect(doc.undoManager?.undoActionName == "Pencil Stroke")
            doc.undoManager?.undo()
            #expect(!doc.isDocumentEdited)
            #expect(doc.content?.activeLayer.raster.rgbaBytes == transparent)
            #expect(canvas.displayedRaster.rgbaBytes == transparent)
            #expect(doc.undoManager?.canUndo == false)
            doc.undoManager?.redo()
            #expect(doc.isDocumentEdited)
            #expect(doc.content?.activeLayer.raster.rgbaBytes == painted)
            #expect(canvas.displayedRaster.rgbaBytes == painted)
            doc.undoManager?.undo()
            #expect(!doc.isDocumentEdited && canvas.displayedRaster.rgbaBytes == transparent)
        }
        canvas.zoom(to: 8)
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        canvas.mouseDown(with: try event(.leftMouseDown, center))
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            ))
        canvas.keyDown(with: escape)
        #expect(doc.stroke == nil && !doc.isDocumentEdited)
        #expect(doc.content?.activeLayer.raster.rgbaBytes == transparent)
        #expect(canvas.displayedRaster.rgbaBytes == transparent)
        controller.state.tool = .eyedropper
        #expect(!doc.isDocumentEdited)
        #expect(EditorColor.sample(canvas.displayedRaster, at: canvas.documentPoint(center))?.alpha == 0)
        canvas.mouseDown(with: try event(.leftMouseDown, center))
        #expect(controller.state.foreground.alpha == 0 && !doc.isDocumentEdited)
        canvas.mouseDown(with: try event(.leftMouseDown, center, flags: .option))
        canvas.mouseDragged(with: try event(.leftMouseDragged, center, flags: .option))
        canvas.mouseUp(with: try event(.leftMouseUp, center))
        #expect(!doc.isDocumentEdited)
    }

    @Test func windowInterruptionAndCloseDiscardPreview() throws {
        let doc = try document()
        doc.makeWindowControllers()
        let controller = try #require(doc.windowControllers.first as? EditorWindowController)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.window)
        #expect(doc.stroke == nil && !doc.isDocumentEdited)
        try doc.beginStroke(at: CGPoint(x: 2, y: 2), settings: settings)
        doc.close()
        #expect(doc.stroke == nil && !doc.isDocumentEdited)
    }

    @Test func unchangedLayoutKeepsStrokeAndCanvasReceivesCommitAndUndo() throws {
        let doc = try document()
        defer { doc.close() }
        doc.makeWindowControllers()
        let controller = try #require(doc.windowControllers.first as? EditorWindowController)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let canvas = try #require(controller.state.canvas)
        let before = Data(count: 16 * 16 * 4)
        #expect(canvas.displayedRaster.rgbaBytes == before)
        try doc.beginStroke(at: CGPoint(x: 2.5, y: 2.5), settings: settings)
        canvas.setFrameSize(canvas.frame.size)
        #expect(doc.stroke != nil)
        try doc.commitStroke(at: CGPoint(x: 12.5, y: 2.5))
        #expect(canvas.displayedRaster.image === doc.rendered?.image)
        #expect(canvas.displayedRaster.rgbaBytes.contains { $0 > 0 })
        let painted = try #require(doc.content?.activeLayer.raster.rgbaBytes)
        #expect(canvas.displayedRaster.rgbaBytes == painted)
        doc.undoManager?.undo()
        #expect(doc.content?.activeLayer.raster.rgbaBytes == before)
        #expect(doc.rendered?.rgbaBytes == before)
        #expect(!doc.isDocumentEdited)
        #expect(canvas.displayedRaster.image === doc.rendered?.image)
        #expect(canvas.displayedRaster.rgbaBytes.allSatisfy { $0 == 0 })
        doc.undoManager?.redo()
        #expect(doc.content?.activeLayer.raster.rgbaBytes == painted)
        #expect(doc.rendered?.rgbaBytes == painted)
        #expect(canvas.displayedRaster.rgbaBytes == painted)
        #expect(canvas.displayedRaster.image === doc.rendered?.image)
        #expect(doc.isDocumentEdited)
    }

    private func document() throws -> ChromaDocument {
        let doc = try ChromaDocument(
            content: ImageDocument(
                raster: RasterSurface(size: PixelSize(width: 16, height: 16), background: .transparent)))
        doc.undoManager?.groupsByEvent = false
        doc.updateChangeCount(.changeCleared)
        return doc
    }
}

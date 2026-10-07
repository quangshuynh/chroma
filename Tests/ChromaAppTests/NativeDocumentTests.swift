import AppKit
import ChromaCore
import Testing
import UniformTypeIdentifiers

@testable import ChromaApp

@MainActor
@Suite(.serialized)
struct NativeDocumentTests {
    init() { _ = NSApplication.shared }

    @Test func blankIsUnsavedAndNativePackageIsValid() throws {
        let content = try blank()
        let document = try ChromaDocument(content: content)
        defer { document.close() }
        #expect(document.isDocumentEdited)
        #expect(document.fileURL == nil)
        let decoded = try NativeDocumentCodec.decode(document.fileWrapper(ofType: NativeDocumentCodec.type.identifier))
        #expect(decoded.size == content.size)
    }

    @Test func openingPreservesSourceAndIsClean() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageCodec.export(blank(), to: url, format: .png)
        let bytes = try Data(contentsOf: url)
        let document = try ChromaDocument(contentsOf: url, ofType: UTType.png.identifier)
        defer { document.close() }
        #expect(!document.isDocumentEdited)
        #expect(document.fileURL == url)
        #expect(document.content?.size == (try PixelSize(width: 64, height: 32)))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func nativeSaveWritesPackageAndClearsDirtyState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        try await document.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveAsOperation)
        #expect(!document.isDocumentEdited)
        #expect(document.fileURL == url)
        #expect(try NativeDocumentCodec.read(from: url).size == document.content?.size)
    }

    @Test func failedNativeSaveKeepsUnsavedContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "/missing/image.chroma")
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        do {
            try await document.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveAsOperation)
            Issue.record("Saving to a nonexistent directory should fail")
        } catch {
            #expect(document.isDocumentEdited)
            #expect(document.fileURL == nil)
            #expect(document.content != nil)
        }
    }

    @Test func windowNavigationLeavesDocumentClean() throws {
        let document = try ChromaDocument(content: blank())
        document.updateChangeCount(.changeCleared)
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let window = try #require(controller.window)
        #expect(window.minSize == NSSize(width: 640, height: 460))
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = try #require(controller.state.canvas)
        controller.actualSize(nil)
        #expect(canvas.zoomFactor == 1)
        controller.zoomIn(nil)
        controller.zoomIn(nil)
        #expect(canvas.zoomFactor == 1.5625)
        controller.zoomOut(nil)
        #expect(canvas.zoomFactor == 1.25)
        controller.fitImage(nil)
        #expect(canvas.zoomFactor > 1.25)
        controller.toggleInspector(nil)
        #expect(!document.isDocumentEdited)
        #expect(!controller.state.inspectorVisible)
    }

    @Test func failedOpenReportsError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken image".utf8).write(to: url)
        #expect(throws: ImageError.unreadableImage) {
            try ChromaDocument(contentsOf: url, ofType: UTType.png.identifier)
        }
    }

    @Test func allLayerEditsUndoAndRedoWithStableIDs() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        let manager = try #require(document.undoManager)
        manager.groupsByEvent = false
        document.updateChangeCount(.changeCleared)
        let original = try #require(document.content)
        try document.perform(.add)
        let added = try #require(document.content?.activeLayerID)
        try document.perform(.rename(added, "Highlights"))
        try document.perform(.opacity(added, 0.4))
        try document.perform(.visibility(added, false))
        try document.perform(.duplicate(added))
        let duplicate = try #require(document.content?.activeLayerID)
        try document.perform(.move(duplicate, to: 0))
        try document.perform(.delete(added))
        #expect(document.isDocumentEdited)
        #expect(manager.undoActionName == "Delete Layer")
        let final = try #require(document.content)
        for _ in 0..<7 { manager.undo() }
        #expect(document.content?.layers.map(\.id) == original.layers.map(\.id))
        #expect(!document.isDocumentEdited)
        #expect(!manager.canUndo)
        for _ in 0..<7 { manager.redo() }
        #expect(document.content?.layers.map(\.id) == final.layers.map(\.id))
        #expect(document.content?.activeLayerID == duplicate)
        #expect(document.content?.activeLayer.opacity == 0.4)
        #expect(document.content?.activeLayer.isVisible == false)
        #expect(document.isDocumentEdited)
    }

    @Test func selectionRenameAndNoOpsReuseCompositeAndNavigationStaysClean() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        try document.perform(.add)
        document.updateChangeCount(.changeCleared)
        let before = try #require(document.rendered)
        let id = try #require(document.content?.layers[0].id)
        try document.selectLayer(id)
        #expect(!document.isDocumentEdited)
        #expect(document.rendered?.image === before.image)
        #expect(try !document.perform(.opacity(id, 1)))
        #expect(!document.isDocumentEdited)
        try document.perform(.rename(id, "Base"))
        #expect(document.isDocumentEdited)
        #expect(document.rendered?.image === before.image)
        document.undoManager?.undo()
        #expect(!document.isDocumentEdited)
    }

    @Test func mergeAndFlattenUndoRestoreMetadataAndPixels() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        try document.perform(.add)
        try document.perform(.opacity(document.content!.activeLayerID, 0.25))
        let before = try #require(document.content)
        try document.perform(.mergeDown(before.activeLayerID))
        #expect(document.content?.layers.count == 1)
        document.undoManager?.undo()
        #expect(document.content?.layers.map(\.id) == before.layers.map(\.id))
        #expect(document.content?.activeLayer.opacity == 0.25)
        document.undoManager?.redo()
        document.undoManager?.undo()
        try document.perform(.flatten)
        #expect(document.content?.layers.count == 1)
        document.undoManager?.undo()
        #expect(document.content?.layers.map(\.id) == before.layers.map(\.id))
        #expect(
            try LayerCompositor.composite(document.content!).rgbaBytes == LayerCompositor.composite(before).rgbaBytes)
    }

    @Test func layeredNativeSaveReopenAndUndoToSavedState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        try document.perform(.add)
        let id = document.content!.activeLayerID
        try document.perform(.rename(id, "Paint"))
        try await document.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveAsOperation)
        #expect(!document.isDocumentEdited)
        try document.perform(.visibility(id, false))
        #expect(document.isDocumentEdited)
        document.undoManager?.undo()
        #expect(!document.isDocumentEdited)
        document.undoManager?.redo()
        #expect(document.isDocumentEdited)
        let reopened = try ChromaDocument(contentsOf: url, ofType: NativeDocumentCodec.type.identifier)
        defer { reopened.close() }
        #expect(!reopened.isDocumentEdited)
        #expect(reopened.content?.layers.count == 2)
        #expect(reopened.content?.activeLayer.id == id)
        #expect(reopened.content?.activeLayer.name == "Paint")
        #expect(reopened.content?.activeLayer.isVisible == true)
        let edited = try #require(document.content)
        let png = try ImageCodec.encode(edited, format: .png)
        let jpeg = try ImageCodec.encode(edited, format: .jpeg)
        #expect(!png.isEmpty && !jpeg.isEmpty)
        #expect(document.fileURL == url && document.isDocumentEdited)
        // Safe replacement of an existing package, with the updated layer metadata.
        try await document.save(to: url, ofType: NativeDocumentCodec.type.identifier, for: .saveOperation)
        #expect(!document.isDocumentEdited)
        #expect(try NativeDocumentCodec.read(from: url).activeLayer.isVisible == false)
    }

    @Test func failedEditAndFailedNativeReadLeaveContentAndHistoryIntact() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        document.updateChangeCount(.changeCleared)
        let content = try #require(document.content)
        #expect(throws: LayerError.lastLayer) { try document.perform(.delete(content.activeLayerID)) }
        #expect(!document.isDocumentEdited)
        #expect(document.undoManager?.canUndo == false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: NativeDocumentError.malformed) {
            try document.read(from: url, ofType: NativeDocumentCodec.type.identifier)
        }
        #expect(document.content?.id == content.id)
        #expect(document.content?.layers.map(\.id) == content.layers.map(\.id))
    }

    @Test func windowReceivesEditsWithoutResettingZoomAndMenuValidationFollowsSelection() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.actualSize(nil)
        controller.zoomIn(nil)
        controller.addLayer(nil)
        #expect(controller.presentation.content.layers.count == 2)
        #expect(controller.state.canvas?.zoomFactor == 1.25)
        let merge = NSMenuItem(
            title: "Merge Down", action: #selector(EditorWindowController.mergeDown(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(merge))
        try document.selectLayer(document.content!.layers[0].id)
        #expect(!controller.validateMenuItem(merge))
        let canvas = try #require(controller.state.canvas)
        #expect(canvas.accessibilityLabel()?.contains("Image canvas") == true)
    }

    @Test func renameDraftSelectionAndUndoCannotReapplyStaleText() throws {
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        let manager = try #require(document.undoManager)
        manager.groupsByEvent = false
        try document.perform(.add)
        let first = document.content!.layers[0].id
        let second = document.content!.layers[1].id
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let presentation = controller.presentation
        presentation.select(first)
        manager.removeAllActions()
        document.updateChangeCount(.changeCleared)
        presentation.draftName = "Renamed base"
        #expect(!document.isDocumentEdited)
        presentation.select(second)
        #expect(document.content?.layers[0].name == "Renamed base")
        presentation.select(first)
        manager.undo()
        #expect(document.content?.layers[0].name == "Background")
        #expect(presentation.draftName == document.content?.activeLayer.name)
        #expect(manager.canRedo)
        #expect(!manager.canUndo)
        #expect(!document.isDocumentEdited)
        // Losing text focus after the undo refresh is a no-op, not another rename.
        #expect(presentation.commitName())
        #expect(manager.canRedo)
        manager.redo()
        #expect(document.content?.layers[0].name == "Renamed base")
        #expect(document.isDocumentEdited)
    }

    private func blank() throws -> ImageDocument {
        ImageDocument(raster: try RasterSurface(size: PixelSize(width: 64, height: 32), background: .transparent))
    }
}

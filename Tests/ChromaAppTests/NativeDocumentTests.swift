import AppKit
import ChromaCore
import Testing
import UniformTypeIdentifiers

@testable import ChromaApp

@MainActor
@Suite(.serialized)
struct NativeDocumentTests {
    init() { _ = NSApplication.shared }

    @Test func blankIsUnsavedAndPNGDataIsValid() throws {
        let content = try blank()
        let document = ChromaDocument(content: content)
        defer { document.close() }
        #expect(document.isDocumentEdited)
        #expect(document.fileURL == nil)
        let decoded = try ImageCodec.decode(data: document.data(ofType: UTType.png.identifier))
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

    @Test func nativeSaveWritesPNGAndClearsDirtyState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        try await document.save(to: url, ofType: UTType.png.identifier, for: .saveAsOperation)
        #expect(!document.isDocumentEdited)
        #expect(document.fileURL == url)
        #expect(try ImageCodec.decode(url: url).size == document.content?.size)
    }

    @Test func failedNativeSaveKeepsUnsavedContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "/missing/image.png")
        let document = try ChromaDocument(content: blank())
        defer { document.close() }
        do {
            try await document.save(to: url, ofType: UTType.png.identifier, for: .saveAsOperation)
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

    private func blank() throws -> ImageDocument {
        ImageDocument(raster: try RasterSurface(size: PixelSize(width: 64, height: 32), background: .transparent))
    }
}

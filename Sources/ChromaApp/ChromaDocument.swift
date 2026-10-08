import AppKit
import ChromaCore
import UniformTypeIdentifiers

@MainActor
final class ChromaDocument: NSDocument {
    // Worker-thread reads exchange only immutable snapshots through this lock.
    private nonisolated let storage = DocumentStorage()
    private(set) var stroke: PixelStroke?
    private(set) var selection: SelectionMask?
    private(set) var movement: PixelMove?
    var content: ImageDocument? { storage.snapshot?.content }
    var rendered: RasterSurface? { storage.snapshot?.raster }

    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    override class var autosavesInPlace: Bool { false }
    override class var writableTypes: [String] { [NativeDocumentCodec.type.identifier] }
    override class var readableTypes: [String] {
        [NativeDocumentCodec.type.identifier] + ImageCodec.supportedInputTypes.map(\.identifier)
    }

    convenience init(content: ImageDocument) throws {
        self.init()
        storage.replace(content, raster: try LayerCompositor.composite(content))
        fileType = NativeDocumentCodec.type.identifier
        updateChangeCount(.changeDone)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let content =
            try typeName == NativeDocumentCodec.type.identifier
            ? NativeDocumentCodec.read(from: url) : ImageCodec.decode(url: url)
        storage.replace(content, raster: try LayerCompositor.composite(content))
        Task { @MainActor [weak self] in
            self?.cancelTransientEdits()
            self?.setSelection(nil)
            self?.refreshWindows()
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard typeName == NativeDocumentCodec.type.identifier, let content else { throw ImageError.encodingFailed }
        return try NativeDocumentCodec.fileWrapper(for: content)
    }

    override func makeWindowControllers() {
        guard let snapshot = storage.snapshot else { return }
        addWindowController(EditorWindowController(content: snapshot.content, raster: snapshot.raster, owner: self))
    }

    @discardableResult
    func perform(_ edit: LayerEdit) throws -> Bool {
        cancelTransientEdits()
        guard let previous = content else { return false }
        var next = previous
        guard try next.apply(edit) else { return false }
        try restore(next, actionName: edit.actionName)
        return true
    }

    func selectLayer(_ id: UUID) throws {
        cancelTransientEdits()
        guard var next = content, let raster = rendered else { return }
        try next.selectLayer(id)
        storage.replace(next, raster: raster)
        refreshWindows()
    }

    private func restore(_ next: ImageDocument, actionName: String, preparedRaster: RasterSurface? = nil) throws {
        cancelTransientEdits()
        guard let previous = content else { return }
        // Compute before changing content/history. Failed allocation leaves the old document intact.
        let raster =
            try preparedRaster
            ?? (previous.renderRevision == next.renderRevision
                ? (rendered ?? LayerCompositor.composite(next)) : LayerCompositor.composite(next))
        let manager = undoManager
        let needsGroup = manager.map { !$0.isUndoing && !$0.isRedoing } ?? false
        if needsGroup { manager?.beginUndoGrouping() }
        defer { if needsGroup { manager?.endUndoGrouping() } }
        manager?.registerUndo(withTarget: self) { target in
            // AppKit's document responder chain and our programmatic callers undo on the main actor.
            // Older SDKs do not annotate this synchronous callback; keep redo in the current undo group.
            MainActor.assumeIsolated {
                do { try target.restore(previous, actionName: actionName) } catch { target.presentError(error) }
            }
        }
        undoManager?.setActionName(actionName)
        if previous.size != next.size { selection = nil }
        storage.replace(next, raster: raster)
        // NSDocument observes its UndoManager to track edits and saved-state traversal.
        refreshWindows()
    }

    func beginStroke(at point: CGPoint, settings: StrokeSettings) throws {
        cancelTransientEdits()
        guard let content else { return }
        let next = try PixelStroke(document: content, settings: settings, selection: selection)
        next.append(point)
        try next.refreshPreview()
        stroke = next
        refreshStrokeViews()
    }

    func continueStroke(at point: CGPoint) throws {
        guard let stroke, let content else { return }
        do {
            try stroke.validate(content)
            stroke.append(point)
            try stroke.refreshPreview()
            refreshStrokeViews()
        } catch {
            cancelTransientEdits()
            throw error
        }
    }

    func commitStroke(at point: CGPoint) throws {
        guard let stroke, var next = content else { return }
        defer { cancelStroke() }
        stroke.append(point)
        guard let raster = try stroke.finish(in: next) else { return }
        try next.replaceRaster(raster, for: stroke.layerID)
        let composite = try rendered.map { try stroke.compositedPreview(over: $0) }
        try restore(next, actionName: stroke.settings.tool.rawValue + " Stroke", preparedRaster: composite)
    }

    func cancelStroke() {
        guard stroke != nil else { return }
        stroke = nil
        refreshStrokeViews()
    }

    func cancelTransientEdits() {
        cancelStroke()
        cancelMove()
        for case let controller as EditorWindowController in windowControllers {
            controller.state.canvas?.discardGesture()
        }
    }

    func setSelection(_ mask: SelectionMask?) {
        cancelTransientEdits()
        guard mask == nil || mask?.size == content?.size else { return }
        selection = mask
        refreshSelectionViews()
    }

    var selectionDescription: String { (movement?.movedSelection ?? selection)?.description ?? "No selection" }

    private func refreshSelectionViews() {
        for case let controller as EditorWindowController in windowControllers {
            controller.state.canvas?.selectionChanged()
        }
    }

    func beginMove() throws {
        cancelTransientEdits()
        guard let content, let selection, selection.bounds != nil else { return }
        movement = try PixelMove(document: content, selection: selection)
    }
    func continueMove(dx: Int, dy: Int) throws {
        guard let movement, let content else { return }
        do {
            try movement.validate(content)
            try movement.update(dx: dx, dy: dy)
            refreshSelectionViews()
        } catch {
            cancelMove()
            throw error
        }
    }
    func commitMove() throws {
        guard let movement, var next = content else { return }
        defer { cancelMove() }
        let movedSelection = movement.movedSelection
        if let raster = try movement.finish(in: next) {
            try next.replaceRaster(raster, for: next.activeLayerID)
            try restore(next, actionName: "Move Selected Pixels")
        }
        selection = movedSelection
        refreshSelectionViews()
    }
    func cancelMove() {
        guard movement != nil else { return }
        movement = nil
        refreshSelectionViews()
    }

    func copyPixels(to pasteboard: NSPasteboard) throws -> Bool {
        cancelTransientEdits()
        guard let content, let raster = try RegionEditing.copy(content.activeLayer.raster, selection: selection) else {
            return false
        }
        return try RasterClipboard.write(raster, to: pasteboard)
    }
    func cutPixels(to pasteboard: NSPasteboard) throws {
        if try copyPixels(to: pasteboard) { try deletePixels(actionName: "Cut") }
    }
    func deletePixels(actionName: String = "Delete Selected Pixels") throws {
        cancelTransientEdits()
        guard var next = content,
            let raster = try RegionEditing.delete(next.activeLayer.raster, selection: selection)
        else { return }
        try next.replaceRaster(raster, for: next.activeLayerID)
        try restore(next, actionName: actionName)
    }
    func pastePixels(from pasteboard: NSPasteboard) throws {
        cancelTransientEdits()
        guard let content, let raster = try RasterClipboard.read(from: pasteboard) else { return }
        let next = try RegionEditing.paste(raster, into: content)
        try restore(next, actionName: "Paste")
        setSelection(.rectangle(CGRect(origin: .zero, size: raster.size.cgSize), size: next.size))
    }
    func cropToSelection() throws {
        cancelTransientEdits()
        guard let content, let selection, let next = try RegionEditing.crop(content, selection: selection) else {
            return
        }
        try restore(next, actionName: "Crop to Selection")
    }

    private func refreshStrokeViews() {
        for case let controller as EditorWindowController in windowControllers {
            controller.state.canvas?.needsDisplay = true
        }
    }

    override func close() {
        cancelTransientEdits()
        super.close()
    }

    private func refreshWindows() {
        guard let snapshot = storage.snapshot else { return }
        for case let controller as EditorWindowController in windowControllers {
            controller.presentation.update(content: snapshot.content, raster: snapshot.raster)
            controller.state.canvas?.update(snapshot.raster)
            controller.state.canvas?.selectionChanged()
        }
    }

    override func save(_ sender: Any?) {
        cancelTransientEdits()
        if fileType == NativeDocumentCodec.type.identifier, fileURL != nil {
            super.save(sender)
        } else {
            saveAs(sender)
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        cancelTransientEdits()
        savePanel.allowedContentTypes = [NativeDocumentCodec.type]
        savePanel.title = "Save Chroma Document"
        savePanel.message = "Preserve all layers and transparency in an editable Chroma document."
        savePanel.nameFieldStringValue = ((displayName as NSString).deletingPathExtension) + ".chroma"
        return true
    }
}

@MainActor
final class ChromaDocumentController: NSDocumentController {
    private var newWindow: NSWindowController?

    override var defaultType: String? { NativeDocumentCodec.type.identifier }
    override func documentClass(forType typeName: String) -> AnyClass? { ChromaDocument.self }

    override func newDocument(_ sender: Any?) {
        if let window = newWindow?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NewDocumentWindowController { [weak self] content in
            guard let self else { return }
            let document: ChromaDocument
            do { document = try ChromaDocument(content: content) } catch {
                NSApp.presentError(error)
                return
            }
            addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        }
        newWindow = controller
        controller.showWindow(nil)
    }
}

private final class DocumentStorage: @unchecked Sendable {
    struct Snapshot {
        let content: ImageDocument
        let raster: RasterSurface
    }
    private let lock = NSLock()
    private var value: Snapshot?
    var snapshot: Snapshot? { lock.withLock { value } }
    func replace(_ content: ImageDocument, raster: RasterSurface) {
        lock.withLock { value = Snapshot(content: content, raster: raster) }
    }
}

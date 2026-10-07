import AppKit
import ChromaCore
import UniformTypeIdentifiers

@MainActor
final class ChromaDocument: NSDocument {
    // NSDocument may read on its worker thread. The immutable model crosses that
    // boundary through a lock, never through a UI object or unchecked actor access.
    private nonisolated let storage = DocumentStorage()
    var content: ImageDocument? { storage.snapshot }

    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override class var autosavesInPlace: Bool { false }
    override class var writableTypes: [String] { [UTType.png.identifier] }
    override class var readableTypes: [String] { ImageCodec.supportedInputTypes.map(\.identifier) }

    convenience init(content: ImageDocument) {
        self.init()
        storage.replace(with: content)
        fileType = UTType.png.identifier
        updateChangeCount(.changeDone)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        storage.replace(with: try ImageCodec.decode(url: url))
    }

    override func data(ofType typeName: String) throws -> Data {
        guard typeName == UTType.png.identifier, let content else { throw ImageError.encodingFailed }
        return try ImageCodec.encode(content, format: .png)
    }

    override func makeWindowControllers() {
        guard let content else { return }
        addWindowController(EditorWindowController(content: content))
    }

    // Every save offers a destination and the native replacement confirmation, including imported PNGs.
    // NSDocument owns safe writing, dirty state, close/quit prompts, and filename updates.
    override func save(_ sender: Any?) { saveAs(sender) }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [.png]
        savePanel.title = "Save PNG"
        savePanel.message = "Save a lossless PNG image. Transparency is preserved."
        savePanel.nameFieldStringValue = ((displayName as NSString).deletingPathExtension) + ".png"
        return true
    }
}

@MainActor
final class ChromaDocumentController: NSDocumentController {
    private var newWindow: NSWindowController?

    override var defaultType: String? { UTType.png.identifier }
    override func documentClass(forType typeName: String) -> AnyClass? { ChromaDocument.self }

    override func newDocument(_ sender: Any?) {
        if let window = newWindow?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NewDocumentWindowController { [weak self] content in
            guard let self else { return }
            let document = ChromaDocument(content: content)
            addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        }
        newWindow = controller
        controller.showWindow(nil)
    }
}

private final class DocumentStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ImageDocument?
    var snapshot: ImageDocument? { lock.withLock { value } }
    func replace(with content: ImageDocument) { lock.withLock { value = content } }
}

import AppKit
import ChromaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: ChromaDocumentController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        documents = ChromaDocumentController()
        installMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        documents.newDocument(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.newDocument(nil) }
        return true
    }

    private func installMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        let app = submenu("Chroma", in: main)
        item("About Chroma", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app)
        app.addItem(.separator())
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item("Hide Chroma", #selector(NSApplication.hide(_:)), key: "h", in: app)
        item(
            "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
            modifiers: [.command, .option], in: app)
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), in: app)
        app.addItem(.separator())
        item("Quit Chroma", #selector(NSApplication.terminate(_:)), key: "q", in: app)

        let file = submenu("File", in: main)
        item("New…", #selector(NSDocumentController.newDocument(_:)), key: "n", in: file)
        item("Open…", #selector(NSDocumentController.openDocument(_:)), key: "o", in: file)
        file.addItem(.separator())
        item("Close", #selector(NSWindow.performClose(_:)), key: "w", in: file)
        item("Save PNG…", #selector(NSDocument.save(_:)), key: "s", in: file)
        item(
            "Export JPEG…", #selector(EditorWindowController.exportJPEG(_:)), key: "e", modifiers: [.command, .shift],
            in: file)

        let edit = submenu("Edit", in: main)
        item("Undo", Selector(("undo:")), key: "z", in: edit)
        item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], in: edit)
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), key: "x", in: edit)
        item("Copy", #selector(NSText.copy(_:)), key: "c", in: edit)
        item("Paste", #selector(NSText.paste(_:)), key: "v", in: edit)
        item("Select All", #selector(NSText.selectAll(_:)), key: "a", in: edit)

        let view = submenu("View", in: main)
        item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), key: "=", in: view)
        item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), key: "-", in: view)
        item("Actual Size", #selector(EditorWindowController.actualSize(_:)), key: "0", in: view)
        item(
            "Fit Image", #selector(EditorWindowController.fitImage(_:)), key: "0", modifiers: [.command, .shift],
            in: view)
        view.addItem(.separator())
        item(
            "Toggle Image Info", #selector(EditorWindowController.toggleInspector(_:)), key: "i",
            modifiers: [.command, .option], in: view)
        let window = submenu("Window", in: main)
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", in: window)
        item("Zoom", #selector(NSWindow.performZoom(_:)), in: window)
        window.addItem(.separator())
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), in: window)
        NSApp.windowsMenu = window
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    private func item(
        _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
        in menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}

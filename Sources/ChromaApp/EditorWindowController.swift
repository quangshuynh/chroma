import AppKit
import ChromaCore
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSMenuItemValidation {
    let state = EditorState()
    let presentation: EditorPresentation
    private var isExporting = false

    init(content: ImageDocument, raster: RasterSurface, owner: ChromaDocument) {
        self.presentation = EditorPresentation(content: content, raster: raster, owner: owner)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.title = "Untitled"
        window.tabbingMode = .preferred
        super.init(window: window)
        window.contentView = NSHostingView(rootView: EditorView(presentation: presentation, state: state))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func zoomIn(_ sender: Any?) { state.canvas?.zoomBy(1.25) }
    @objc func zoomOut(_ sender: Any?) { state.canvas?.zoomBy(1 / 1.25) }
    @objc func actualSize(_ sender: Any?) { state.canvas?.zoom(to: 1) }
    @objc func fitImage(_ sender: Any?) { state.canvas?.fit() }
    @objc func toggleInspector(_ sender: Any?) { state.inspectorVisible.toggle() }

    @objc func exportJPEG(_ sender: Any?) { export(.jpeg) }
    @objc func exportPNG(_ sender: Any?) { export(.png) }

    private func export(_ format: ExportFormat) {
        guard let window, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.title = format == .jpeg ? "Export JPEG" : "Export PNG"
        panel.message =
            format == .png
            ? "Export the visible composite with transparency. Your layered document stays unchanged."
            : "Transparent pixels will be flattened onto white. JPEG uses lossy compression. Your open document stays unchanged."
        panel.nameFieldStringValue =
            (((document as? NSDocument)?.displayName ?? "Untitled") as NSString).deletingPathExtension
            + (format == .jpeg ? ".jpg" : ".png")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.isExporting = true
            let snapshot = self.presentation.content
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ImageCodec.export(snapshot, to: url, format: format)
                    }.value
                } catch { self.presentError(error) }
                self.isExporting = false
            }
        }
    }

    @objc func addLayer(_ sender: Any?) { presentation.perform(.add) }
    @objc func duplicateLayer(_ sender: Any?) { presentation.perform(.duplicate(presentation.content.activeLayerID)) }
    @objc func deleteLayer(_ sender: Any?) { presentation.perform(.delete(presentation.content.activeLayerID)) }
    @objc func moveLayerUp(_ sender: Any?) {
        presentation.perform(.move(presentation.content.activeLayerID, to: presentation.content.activeIndex + 1))
    }
    @objc func moveLayerDown(_ sender: Any?) {
        presentation.perform(.move(presentation.content.activeLayerID, to: presentation.content.activeIndex - 1))
    }
    @objc func mergeDown(_ sender: Any?) { presentation.perform(.mergeDown(presentation.content.activeLayerID)) }
    @objc func flattenImage(_ sender: Any?) { presentation.perform(.flatten) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addLayer(_:)), #selector(duplicateLayer(_:)): return presentation.content.canAddLayer
        case #selector(deleteLayer(_:)): return presentation.content.layers.count > 1
        case #selector(moveLayerUp(_:)): return presentation.content.activeIndex < presentation.content.layers.count - 1
        case #selector(moveLayerDown(_:)): return presentation.content.activeIndex > 0
        case #selector(mergeDown(_:)): return presentation.content.canMergeDown
        case #selector(flattenImage(_:)):
            let content = presentation.content
            return content.layers.count > 1 || !content.layers[0].isVisible || content.layers[0].opacity != 1
        case #selector(exportJPEG(_:)), #selector(exportPNG(_:)): return !isExporting
        case #selector(zoomIn(_:)): return state.zoom < Viewport.zoomRange.upperBound
        case #selector(zoomOut(_:)): return state.zoom > Viewport.zoomRange.lowerBound
        case #selector(toggleInspector(_:)):
            menuItem.state = state.inspectorVisible ? .on : .off
            return true
        default: return true
        }
    }
}

private struct EditorView: View {
    @ObservedObject var presentation: EditorPresentation
    private var content: ImageDocument { presentation.content }
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Canvas", systemImage: "hand.draw").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        state.canvas?.zoomBy(1 / 1.25)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }.help("Zoom Out (⌘−)").accessibilityLabel("Zoom out")
                        .disabled(state.zoom <= Viewport.zoomRange.lowerBound)
                    Text(state.zoom, format: .percent.precision(.fractionLength(0...1)))
                        .monospacedDigit().frame(minWidth: 62).accessibilityLabel("Zoom")
                        .accessibilityValue(state.zoom.formatted(.percent))
                    Button {
                        state.canvas?.zoomBy(1.25)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }.help("Zoom In (⌘+)").accessibilityLabel("Zoom in")
                        .disabled(state.zoom >= Viewport.zoomRange.upperBound)
                }
                Button("100%") { state.canvas?.zoom(to: 1) }.help("Actual Size (⌘0): one image pixel per display pixel")
                Button("Fit") { state.canvas?.fit() }.help("Fit Image (⇧⌘0)")
                Divider().frame(height: 18)
                Button {
                    state.inspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }.help("Toggle Inspector (⌥⌘I)").accessibilityLabel("Toggle layers inspector")
            }
            .buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 42)
            Divider()
            HStack(spacing: 0) {
                CanvasView(content: presentation.raster, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.inspectorVisible {
                    Divider()
                    LayersInspector(presentation: presentation)
                        .frame(width: 260)
                        .background(.background)
                }
            }
            Divider()
            HStack {
                Text("\(content.size.width) × \(content.size.height) px").monospacedDigit()
                Spacer()
                Text("Scroll or drag to pan · Pinch to zoom")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: 28)
        }
    }
}

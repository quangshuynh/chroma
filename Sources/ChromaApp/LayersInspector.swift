import AppKit
import ChromaCore
import SwiftUI

/// Presentation snapshots are refreshed only at the document mutation boundary.
/// Observing zoom or recomputing a SwiftUI body cannot invoke the compositor.
@MainActor
final class EditorPresentation: ObservableObject {
    @Published private(set) var content: ImageDocument
    @Published var draftName: String
    private(set) var raster: RasterSurface
    weak var owner: ChromaDocument?

    init(content: ImageDocument, raster: RasterSurface, owner: ChromaDocument) {
        self.content = content
        self.raster = raster
        self.owner = owner
        self.draftName = content.activeLayer.name
    }

    func update(content: ImageDocument, raster: RasterSurface) {
        self.raster = raster
        self.content = content
        // Snapshot synchronization (including undo) is read-only: never commit stale UI drafts.
        self.draftName = content.activeLayer.name
    }

    func perform(_ edit: LayerEdit) {
        guard commitName() else { return }
        do { try owner?.perform(edit) } catch { owner?.presentError(error) }
    }

    @discardableResult
    func commitName() -> Bool {
        guard draftName != content.activeLayer.name else { return true }
        do {
            try owner?.perform(.rename(content.activeLayerID, draftName))
            draftName = content.activeLayer.name
            return true
        } catch {
            draftName = content.activeLayer.name
            owner?.presentError(error)
            return false
        }
    }

    func select(_ id: UUID?) {
        guard let id, commitName() else { return }
        do { try owner?.selectLayer(id) } catch { owner?.presentError(error) }
    }
}

struct LayersInspector: View {
    @ObservedObject var presentation: EditorPresentation
    @State private var opacity = 100.0
    @State private var adjustingOpacity = false
    @FocusState private var editingName: Bool
    private var content: ImageDocument { presentation.content }
    private var active: RasterLayer { content.activeLayer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Text("\(content.layers.count)").foregroundStyle(.secondary).monospacedDigit()
            }.padding(14)
            List(selection: Binding<UUID?>(get: { content.activeLayerID }, set: { presentation.select($0) })) {
                ForEach(content.layers.reversed()) { layer in
                    HStack(spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { layer.isVisible },
                                set: {
                                    presentation.perform(.visibility(layer.id, $0))
                                })
                        ) {
                            Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        }
                        .toggleStyle(.button).buttonStyle(.borderless)
                        .accessibilityLabel("Show layer \(layer.name)")
                        .accessibilityValue(layer.isVisible ? "Visible" : "Hidden")
                        .help(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")
                        Text(layer.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(layer.opacity, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(layer.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(layer.name)
                    .accessibilityValue(layer.id == content.activeLayerID ? "Selected layer" : "Layer")
                }
            }.listStyle(.inset).accessibilityLabel("Layer stack, top layer first")
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Add", systemImage: "plus") { presentation.perform(.add) }
                        .disabled(!content.canAddLayer).help("Add a transparent layer above the selected layer")
                    Button("Duplicate") { presentation.perform(.duplicate(active.id)) }
                        .disabled(!content.canAddLayer)
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Move Up", systemImage: "arrow.up") {
                        presentation.perform(.move(active.id, to: content.activeIndex + 1))
                    }.disabled(content.activeIndex == content.layers.count - 1)
                    Button("Move Down", systemImage: "arrow.down") {
                        presentation.perform(.move(active.id, to: content.activeIndex - 1))
                    }.disabled(content.activeIndex == 0)
                }.labelStyle(.iconOnly)
                LabeledContent("Name") {
                    TextField("Layer name", text: $presentation.draftName)
                        .focused($editingName)
                        .onSubmit { presentation.commitName() }
                        .onChange(of: editingName) { _, focused in if !focused { presentation.commitName() } }
                        .accessibilityLabel("Selected layer name")
                }
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text(opacity / 100, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { opacity },
                        set: {
                            opacity = $0.rounded()
                            if !adjustingOpacity { commitOpacity() }
                        }), in: 0...100
                ) { editing in
                    adjustingOpacity = editing
                    if !editing { commitOpacity() }
                }
                .accessibilityLabel("Layer opacity")
                .accessibilityValue("\(Int(opacity)) percent")
                .help("Applies when released; one undo step per adjustment")
                HStack {
                    Menu("Merge") {
                        Button("Merge Down") { presentation.perform(.mergeDown(active.id)) }
                            .disabled(!content.canMergeDown)
                        Button("Flatten Image") { presentation.perform(.flatten) }
                    }.help("Merge Down is available for the bottom two layers to preserve exact 8-bit pixels")
                    Spacer()
                    Button("Delete Layer", role: .destructive) { presentation.perform(.delete(active.id)) }
                        .disabled(content.layers.count == 1)
                        .help(
                            content.layers.count == 1
                                ? "A document must keep one layer" : "Delete selected layer (undoable)")
                }
            }.controlSize(.small).padding(14)
            Divider()
            Text("\(content.size.width) × \(content.size.height) px · sRGB · 8-bit RGBA")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .onAppear { syncControls() }
        .onChange(of: content.activeLayerID) { _, _ in syncControls() }
        .onChange(of: active.opacity) { _, _ in if !adjustingOpacity { opacity = active.opacity * 100 } }
    }

    private func syncControls() {
        opacity = active.opacity * 100
    }

    private func commitOpacity() {
        guard opacity / 100 != active.opacity else { return }
        presentation.perform(.opacity(active.id, opacity / 100))
    }
}

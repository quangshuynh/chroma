import AppKit
import ChromaCore
import SwiftUI

@MainActor
final class NewDocumentWindowController: NSWindowController {
    init(create: @escaping (ImageDocument) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "New Image"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: NewDocumentView { [weak self] content in
                self?.close()
                create(content)
            } cancel: { [weak self] in
                self?.close()
            })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct NewDocumentView: View {
    @State private var width = "1280"
    @State private var height = "800"
    @State private var background = ImageBackground.transparent
    @State private var error: String?
    @State private var isCreating = false
    @State private var creationTask: Task<Void, Never>?
    @FocusState private var widthFocused: Bool
    let create: (ImageDocument) -> Void
    let cancel: () -> Void

    private var size: PixelSize? {
        guard let width = Int(width), let height = Int(height) else { return nil }
        return try? PixelSize(width: width, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create an image").font(.title2.weight(.semibold))
            Form {
                TextField("Width (px)", text: $width).focused($widthFocused)
                TextField("Height (px)", text: $height)
                Picker("Background", selection: $background) {
                    ForEach(ImageBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            .textFieldStyle(.roundedBorder)
            Text(
                error
                    ?? (size == nil
                        ? "Use positive whole numbers, up to 16,384 per side and 32 million pixels total."
                        : "Dimensions are in pixels. White creates an opaque image.")
            )
            .font(.callout).foregroundStyle(error == nil ? .secondary : Color.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(error ?? "Image dimensions are in pixels")
            HStack {
                Button("Open Image…") { NSDocumentController.shared.openDocument(nil) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create", action: makeImage)
                    .keyboardShortcut(.defaultAction).disabled(size == nil || isCreating)
            }
        }
        .padding(24).frame(width: 420).disabled(isCreating)
        .onAppear { widthFocused = true }
        .onDisappear { creationTask?.cancel() }
    }

    private func makeImage() {
        guard let size else { return }
        isCreating = true
        let background = background
        creationTask = Task {
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    ImageDocument(raster: try RasterSurface(size: size, background: background))
                }.value
                guard !Task.isCancelled else { return }
                create(content)
            } catch { self.error = error.localizedDescription }
            isCreating = false
        }
    }
}

import AppKit
import ChromaCore
import SwiftUI

@MainActor
final class EditorState: ObservableObject {
    @Published var zoom = 1.0
    @Published var inspectorVisible = true
    weak var canvas: CanvasNSView?
}

struct CanvasView: NSViewRepresentable {
    let content: RasterSurface
    let state: EditorState
    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(content: content, state: state)
        state.canvas = view
        return view
    }
    func updateNSView(_ nsView: CanvasNSView, context: Context) { nsView.update(content) }
}

/// Draws a retained composite. Checkerboard, zoom and pan exist only in this presentation layer.
@MainActor
final class CanvasNSView: NSView {
    private var content: RasterSurface
    private weak var state: EditorState?
    private var viewport = Viewport()
    private var dragging = false
    private var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(content: RasterSurface, state: EditorState) {
        self.content = content
        self.state = state
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image canvas, \(content.size.width) by \(content.size.height) pixels")
        setAccessibilityHelp("Scroll, drag, or use arrow keys to pan. Pinch to zoom. Use View menu for zoom controls.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeViewport()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeViewport()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeViewport()
    }

    private func resizeViewport() {
        if viewport.isFitting { viewport.fit(image: content.size, viewport: bounds.size, backingScale: backingScale) }
        refresh()
    }

    func update(_ raster: RasterSurface) {
        guard content.image !== raster.image else { return }
        content = raster
        needsDisplay = true
    }

    var zoomFactor: Double { viewport.zoom }

    func zoomBy(_ factor: Double) { zoom(to: viewport.zoom * factor) }

    func fit() {
        viewport.fit(image: content.size, viewport: bounds.size, backingScale: backingScale)
        refresh()
    }

    func zoom(to value: Double, at point: CGPoint? = nil) {
        let anchor = point.map { CGPoint(x: $0.x - bounds.midX, y: $0.y - bounds.midY) } ?? .zero
        viewport.setZoom(value, anchor: anchor)
        refresh()
    }

    private func refresh() {
        viewport.constrain(image: content.size, viewport: bounds.size, backingScale: backingScale)
        let zoom = viewport.zoom
        // AppKit layout can run during a SwiftUI update. Publish after that update finishes.
        Task { @MainActor [weak self] in
            guard let self, self.viewport.zoom == zoom else { return }
            self.state?.zoom = zoom
            self.setAccessibilityValue("\(Int(zoom * 100)) percent zoom")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = viewport.imageRect(image: content.size, viewport: bounds.size, backingScale: backingScale)
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(rect)
        // Only visit checker cells within the visible region, even at 3200% zoom.
        let visible = rect.intersection(bounds)
        if !visible.isNull {
            let cell = 8.0
            let startX = Int(floor((visible.minX - rect.minX) / cell))
            let endX = Int(ceil((visible.maxX - rect.minX) / cell))
            let startY = Int(floor((visible.minY - rect.minY) / cell))
            let endY = Int(ceil((visible.maxY - rect.minY) / cell))
            context.setFillColor(CGColor(gray: 0.76, alpha: 1))
            for y in startY..<endY {
                for x in startX..<endX where (x + y).isMultiple(of: 2) {
                    context.fill(
                        CGRect(
                            x: rect.minX + Double(x) * cell, y: rect.minY + Double(y) * cell, width: cell, height: cell)
                    )
                }
            }
        }
        context.interpolationQuality = viewport.zoom >= 1 ? .none : .high
        context.draw(content.image, in: rect)
        context.restoreGState()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragging = true
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        viewport.move(by: CGSize(width: event.deltaX, height: -event.deltaY))
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { NSCursor.pop() }
        dragging = false
    }
    override func scrollWheel(with event: NSEvent) {
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        viewport.move(
            by: CGSize(width: event.scrollingDeltaX * multiplier, height: -event.scrollingDeltaY * multiplier))
        refresh()
    }
    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 200.0 : 40.0
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: step, height: 0)
        case 124: delta = CGSize(width: -step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default:
            super.keyDown(with: event)
            return
        }
        viewport.move(by: delta)
        refresh()
    }

    override func magnify(with event: NSEvent) {
        zoom(to: viewport.zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }
}

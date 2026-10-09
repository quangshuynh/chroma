import AppKit
import ChromaCore
import SwiftUI

@MainActor
final class EditorState: ObservableObject {
    @Published var zoom = 1.0
    @Published var inspectorVisible = true
    @Published var tool: PaintTool = .brush { didSet { canvas?.cancelInteraction() } }
    @Published var diameter = 10 { didSet { canvas?.cancelInteraction() } }
    @Published var foreground = EditorColor.black { didSet { canvas?.cancelInteraction() } }
    @Published var background = EditorColor.white { didSet { canvas?.cancelInteraction() } }
    @Published var message: String?
    @Published var selectionDescription = "No selection"
    weak var canvas: CanvasNSView?
    var settings: StrokeSettings { StrokeSettings(tool: tool, diameter: diameter, color: foreground) }

}

struct CanvasView: NSViewRepresentable {
    @ObservedObject var presentation: EditorPresentation
    let state: EditorState
    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(content: presentation.raster, state: state, presentation: presentation)
        state.canvas = view
        return view
    }
    func updateNSView(_ nsView: CanvasNSView, context: Context) { nsView.update(presentation.raster) }
}

/// Draws a retained composite. Checkerboard, zoom and pan exist only in this presentation layer.
@MainActor
final class CanvasNSView: NSView, NSMenuItemValidation {
    private var content: RasterSurface
    private weak var state: EditorState?
    private var viewport = Viewport()
    private var dragging = false
    private var painting = false
    private var selectionStart: CGPoint?
    private var selectionPreview: SelectionMask?
    private var moveStart: CGPoint?
    private var selectionPath: CGPath?
    private var overlayDamage = CGRect.null
    private var pointer: CGPoint?
    private weak var presentation: EditorPresentation?
    private var owner: ChromaDocument? { presentation?.owner }
    private var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(content: RasterSurface, state: EditorState, presentation: EditorPresentation) {
        self.content = content
        self.state = state
        self.presentation = presentation
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image canvas, \(content.size.width) by \(content.size.height) pixels")
        setAccessibilityHelp(
            "Paint the selected visible layer. Option-drag, scroll, or use arrow keys to pan. Drag to select or move with the selected tool. Escape cancels an unfinished edit. Pinch to zoom."
        )
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            window.acceptsMouseMovedEvents = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(interactionInterrupted), name: NSWindow.didResignKeyNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(interactionInterrupted), name: NSApplication.didResignActiveNotification,
                object: nil)
        } else {
            cancelInteraction()
        }
        resizeViewport()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeViewport()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { resizeViewport() }
    }

    private func resizeViewport() {
        cancelInteraction()
        if viewport.isFitting { viewport.fit(image: content.size, viewport: bounds.size, backingScale: backingScale) }
        refresh()
    }

    func update(_ raster: RasterSurface) {
        guard content.image !== raster.image else { return }
        let resized = content.size != raster.size
        content = raster
        setAccessibilityLabel("Image canvas, \(raster.size.width) by \(raster.size.height) pixels")
        if resized { resizeViewport() }
        needsDisplay = true
    }

    var displayedRaster: RasterSurface { content }

    var zoomFactor: Double { viewport.zoom }

    func zoomBy(_ factor: Double) { zoom(to: viewport.zoom * factor) }

    func fit() {
        cancelInteraction()
        viewport.fit(image: content.size, viewport: bounds.size, backingScale: backingScale)
        refresh()
    }

    func zoom(to value: Double, at point: CGPoint? = nil) {
        cancelInteraction()
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
            self.updateAccessibility()
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
        let previews = owner?.movement?.preview.map { [$0] } ?? owner?.stroke?.previews.values.map { $0 } ?? []
        // Cut replacement holes out of the base, so erased alpha reveals the checkerboard.
        context.saveGState()
        context.addRect(rect)
        for preview in previews { context.addRect(canvasRect(preview.rect)) }
        context.clip(using: .evenOdd)
        context.draw(content.image, in: rect)
        context.restoreGState()
        for preview in previews { context.draw(preview.raster.image, in: canvasRect(preview.rect)) }
        context.restoreGState()
        drawSelection(context)
        drawFootprint(context)
    }

    private func canvasRect(_ rect: CGRect) -> CGRect {
        viewport.canvasRect(fromDocument: rect, image: content.size, viewport: bounds.size, backingScale: backingScale)
    }

    func documentPoint(_ point: CGPoint) -> CGPoint {
        viewport.documentPoint(
            fromCanvas: point, image: content.size, viewport: bounds.size, backingScale: backingScale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .crosshair) }

    private func drawFootprint(_ context: CGContext) {
        guard let pointer, let state, !dragging else { return }
        let point = documentPoint(pointer)
        guard point.x >= 0, point.y >= 0, point.x < Double(content.size.width), point.y < Double(content.size.height)
        else { return }
        guard state.tool.paints else { return }
        let diameter = Double(state.diameter)
        let docRect: CGRect
        if state.tool == .pencil {
            docRect = CGRect(
                x: floor(point.x) - Double(state.diameter / 2), y: floor(point.y) - Double(state.diameter / 2),
                width: diameter, height: diameter)
        } else {
            docRect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
        }
        let rect = canvasRect(docRect)
        context.saveGState()
        for (color, width) in [(NSColor.black, 3.0), (NSColor.white, 1.0)] {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width / backingScale)
            if state.tool == .pencil { context.stroke(rect) } else { context.strokeEllipse(in: rect) }
        }
        context.restoreGState()
    }

    @objc private func interactionInterrupted() { cancelInteraction() }
    func cancelInteraction() {
        owner?.cancelTransientEdits()
        discardGesture()
        window?.invalidateCursorRects(for: self)
    }
    func discardGesture() {
        selectionStart = nil
        selectionPreview = nil
        moveStart = nil
        selectionChanged()
        painting = false
        dragging = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func resignFirstResponder() -> Bool {
        cancelInteraction()
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelInteraction()
        pointer = convert(event.locationInWindow, from: nil)
        guard let pointer, let state else { return }
        state.message = nil
        if event.modifierFlags.contains(.option) {
            dragging = true
            window?.invalidateCursorRects(for: self)
            return
        }
        let point = documentPoint(pointer)
        guard point.x >= 0, point.y >= 0, point.x < Double(content.size.width), point.y < Double(content.size.height)
        else { return }
        if state.tool == .rectangleSelect || state.tool == .ellipseSelect {
            selectionStart = point
            updateSelectionPreview(to: point)
            return
        }
        if state.tool == .moveSelected {
            guard owner?.selection?.contains(x: Int(point.x), y: Int(point.y)) == true else {
                state.message = "Create a selection, then drag inside it to move its pixels."
                return
            }
            do {
                try owner?.beginMove()
                moveStart = point
            } catch { state.message = error.localizedDescription }
            return
        }
        if state.tool == .eyedropper {
            if let color = EditorColor.sample(content, at: point) { state.foreground = color }
            return
        }
        do {
            try owner?.beginStroke(at: point, settings: state.settings)
            painting = owner?.stroke != nil
        } catch {
            state.message = error.localizedDescription
            NSSound.beep()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if dragging {
            viewport.move(by: CGSize(width: event.deltaX, height: -event.deltaY))
            refresh()
        } else if selectionStart != nil, let pointer {
            updateSelectionPreview(to: documentPoint(pointer))
        } else if let moveStart, let pointer {
            updateMove(from: moveStart, to: documentPoint(pointer))
        } else if painting, let pointer {
            do { try owner?.continueStroke(at: documentPoint(pointer)) } catch {
                cancelInteraction()
                state?.message = error.localizedDescription
            }
        }
        if painting || dragging { needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        let point = documentPoint(convert(event.locationInWindow, from: nil))
        if selectionStart != nil {
            updateSelectionPreview(to: point)
            owner?.setSelection(selectionPreview?.bounds == nil ? nil : selectionPreview)
        } else if let moveStart {
            updateMove(from: moveStart, to: point)
            do { try owner?.commitMove() } catch { state?.message = error.localizedDescription }
        } else if painting {
            do { try owner?.commitStroke(at: documentPoint(convert(event.locationInWindow, from: nil))) } catch {
                state?.message = error.localizedDescription
            }
        }
        cancelInteraction()
    }
    override func scrollWheel(with event: NSEvent) {
        cancelInteraction()
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        viewport.move(
            by: CGSize(width: event.scrollingDeltaX * multiplier, height: -event.scrollingDeltaY * multiplier))
        refresh()
    }
    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 200.0 : 40.0
        let delta: CGSize
        switch event.keyCode {
        case 51, 117:
            deleteSelectedPixels(nil)
            return
        case 53:
            cancelInteraction()
            return
        case 123: delta = CGSize(width: step, height: 0)
        case 124: delta = CGSize(width: -step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default:
            super.keyDown(with: event)
            return
        }
        cancelInteraction()
        viewport.move(by: delta)
        refresh()
    }

    private func updateSelectionPreview(to point: CGPoint) {
        guard let selectionStart, let state else { return }
        selectionPreview = .drag(
            from: selectionStart, to: point,
            shape: state.tool == .ellipseSelect ? .ellipse : .rectangle, size: content.size)
        selectionChanged()
    }
    private func updateMove(from start: CGPoint, to point: CGPoint) {
        let dx = Int(min(Double(content.size.width), max(-Double(content.size.width), (point.x - start.x).rounded())))
        let dy = Int(min(Double(content.size.height), max(-Double(content.size.height), (point.y - start.y).rounded())))
        do { try owner?.continueMove(dx: dx, dy: dy) } catch {
            cancelInteraction()
            state?.message = error.localizedDescription
        }
    }
    private var displayedSelection: SelectionMask? {
        selectionPreview ?? owner?.movement?.movedSelection ?? owner?.selection
    }
    func selectionChanged() {
        let nextDamage = (displayedSelection?.bounds ?? .null).union(owner?.movement?.preview?.rect ?? .null)
        let damage = overlayDamage.union(nextDamage)
        overlayDamage = nextDamage
        selectionPath = displayedSelection?.outline()
        let description = displayedSelection?.description ?? "No selection"
        if state?.selectionDescription != description {
            // Layout can cancel a gesture during a SwiftUI update. Publish after layout,
            // and never let an older queued summary replace newer selection state.
            Task { @MainActor [weak self] in
                guard let self, (self.displayedSelection?.description ?? "No selection") == description else { return }
                self.state?.selectionDescription = description
            }
        }
        updateAccessibility()
        if !damage.isNull { setNeedsDisplay(canvasRect(damage).insetBy(dx: -3, dy: -3)) }
    }
    private func updateAccessibility() {
        setAccessibilityValue(
            "\(Int(viewport.zoom * 100)) percent zoom. \(displayedSelection?.description ?? "No selection")")
    }
    private func drawSelection(_ context: CGContext) {
        guard let selectionPath else { return }
        let rect = canvasRect(CGRect(origin: .zero, size: content.size.cgSize))
        let scale = rect.width / Double(content.size.width)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: rect.minX, ty: rect.maxY)
        guard let path = selectionPath.copy(using: &transform) else { return }
        context.saveGState()
        context.clip(to: rect.insetBy(dx: -1, dy: -1))
        context.setLineWidth(2)
        context.setStrokeColor(NSColor.black.cgColor)
        context.addPath(path)
        context.strokePath()
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.setStrokeColor(NSColor.white.cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // Canvas-only responders preserve native text-field and color-control editing shortcuts.
    override func selectAll(_ sender: Any?) {
        cancelInteraction()
        owner?.setSelection(.all(size: content.size))
    }
    @objc func deselect(_ sender: Any?) {
        cancelInteraction()
        owner?.setSelection(nil)
    }
    @objc func invertSelection(_ sender: Any?) {
        cancelInteraction()
        owner?.setSelection(owner?.selection?.inverted() ?? .all(size: content.size))
    }
    private func regionCommand(_ action: (ChromaDocument) throws -> Void) {
        cancelInteraction()
        guard let owner else { return }
        do { try action(owner) } catch {
            state?.message = error.localizedDescription
            owner.presentError(error)
        }
    }
    @objc func copy(_ sender: Any?) { regionCommand { _ = try $0.copyPixels(to: .general) } }
    @objc func cut(_ sender: Any?) { regionCommand { try $0.cutPixels(to: .general) } }
    @objc func paste(_ sender: Any?) { regionCommand { try $0.pastePixels(from: .general) } }
    @objc func deleteSelectedPixels(_ sender: Any?) { regionCommand { try $0.deletePixels() } }
    @objc func cropToSelection(_ sender: Any?) { regionCommand { try $0.cropToSelection() } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let owner, let document = owner.content else { return false }
        switch item.action {
        case #selector(deselect(_:)): return owner.selection != nil
        case #selector(cropToSelection(_:)):
            return owner.selection?.bounds != nil && owner.selection?.bounds?.size != document.size.cgSize
        case #selector(paste(_:)): return document.canAddLayer && RasterClipboard.canRead(.general)
        case #selector(copy(_:)), #selector(cut(_:)), #selector(deleteSelectedPixels(_:)):
            return owner.selection == nil || owner.selection?.bounds != nil
        default: return true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(to: viewport.zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }
}

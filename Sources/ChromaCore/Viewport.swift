import CoreGraphics
import Foundation

/// Zoom is display pixels per image pixel: 100% is one image pixel per physical display pixel.
public struct Viewport: Equatable, Sendable {
    public static let zoomRange = 0.01...32.0
    public private(set) var zoom: Double = 1
    public private(set) var pan: CGPoint = .zero
    public private(set) var isFitting = true
    public init() {}

    public static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
    }

    public static func fitZoom(image: PixelSize, viewport: CGSize, backingScale: Double) -> Double {
        guard viewport.width > 0, viewport.height > 0, backingScale > 0 else { return 1 }
        let margin = 48.0
        return clampedZoom(
            min(
                max(1, viewport.width - margin) * backingScale / Double(image.width),
                max(1, viewport.height - margin) * backingScale / Double(image.height)))
    }

    public mutating func fit(image: PixelSize, viewport: CGSize, backingScale: Double) {
        zoom = Self.fitZoom(image: image, viewport: viewport, backingScale: backingScale)
        pan = .zero
        isFitting = true
    }

    public mutating func setZoom(_ value: Double, anchor: CGPoint = .zero) {
        let next = Self.clampedZoom(value)
        let ratio = next / zoom
        pan = CGPoint(x: anchor.x - (anchor.x - pan.x) * ratio, y: anchor.y - (anchor.y - pan.y) * ratio)
        zoom = next
        isFitting = false
    }

    public mutating func move(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        pan.x += delta.width
        pan.y += delta.height
        isFitting = false
    }

    public mutating func constrain(image: PixelSize, viewport: CGSize, backingScale: Double) {
        let extent = CGSize(
            width: Double(image.width) * zoom / backingScale, height: Double(image.height) * zoom / backingScale)
        // Leave at least 32 points of the image visible, even after prolonged scrolling.
        let limitX = max(0, (extent.width + viewport.width) / 2 - 32)
        let limitY = max(0, (extent.height + viewport.height) / 2 - 32)
        pan.x = min(limitX, max(-limitX, pan.x))
        pan.y = min(limitY, max(-limitY, pan.y))
    }

    public func imageRect(image: PixelSize, viewport: CGSize, backingScale: Double) -> CGRect {
        let size = CGSize(
            width: Double(image.width) * zoom / backingScale, height: Double(image.height) * zoom / backingScale)
        return CGRect(
            x: (((viewport.width - size.width) / 2 + pan.x) * backingScale).rounded() / backingScale,
            y: (((viewport.height - size.height) / 2 + pan.y) * backingScale).rounded() / backingScale,
            width: size.width, height: size.height
        )
    }
    /// AppKit canvas is bottom-left; canonical raster rows are top-left. Backing scale only
    /// participates through imageRect, exactly like drawing (including aligned origins).
    public func documentPoint(fromCanvas point: CGPoint, image: PixelSize, viewport: CGSize, backingScale: Double)
        -> CGPoint
    {
        let rect = imageRect(image: image, viewport: viewport, backingScale: backingScale)
        return CGPoint(
            x: (point.x - rect.minX) * Double(image.width) / rect.width,
            y: (rect.maxY - point.y) * Double(image.height) / rect.height)
    }

    public func canvasRect(fromDocument rect: CGRect, image: PixelSize, viewport: CGSize, backingScale: Double)
        -> CGRect
    {
        let imageRect = imageRect(image: image, viewport: viewport, backingScale: backingScale)
        let scale = imageRect.width / Double(image.width)
        return CGRect(
            x: imageRect.minX + rect.minX * scale, y: imageRect.maxY - rect.maxY * scale,
            width: rect.width * scale, height: rect.height * scale)
    }

}

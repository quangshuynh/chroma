import CoreGraphics
import Foundation

/// Binary selection in top-left document pixels. Nil at the editor boundary means unrestricted;
/// an empty mask selects nothing. Sorted, disjoint half-open row spans avoid per-pixel storage.
public struct SelectionMask: Equatable, Sendable {
    public enum Shape: Sendable { case rectangle, ellipse }
    public let size: PixelSize
    private let rows: [[Range<Int>]]
    public let bounds: CGRect?

    private init(size: PixelSize, rows: [[Range<Int>]]) {
        self.size = size
        self.rows = rows
        var rect: CGRect?
        for (y, spans) in rows.enumerated() {
            for span in spans {
                let row = CGRect(x: span.lowerBound, y: y, width: span.count, height: 1)
                rect = rect.map { $0.union(row) } ?? row
            }
        }
        bounds = rect
    }

    public static func empty(size: PixelSize) -> Self {
        Self(size: size, rows: Array(repeating: [], count: size.height))
    }
    public static func all(size: PixelSize) -> Self {
        Self(size: size, rows: Array(repeating: [0..<size.width], count: size.height))
    }

    /// Drag endpoints snap down to pixel edges, then normalize in every direction. A click
    /// or zero-width/height drag is empty. Bound extreme inputs before arithmetic; rasterization
    /// clips the original geometry, so an ellipse dragged past an edge is not reshaped.
    public static func drag(from start: CGPoint, to end: CGPoint, shape: Shape, size: PixelSize) -> Self {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return .empty(size: size) }
        func edge(_ value: Double) -> Double { floor(min(1e9, max(-1e9, value))) }
        let rect = CGRect(
            x: min(edge(start.x), edge(end.x)), y: min(edge(start.y), edge(end.y)),
            width: abs(edge(end.x) - edge(start.x)), height: abs(edge(end.y) - edge(start.y)))
        return shape == .rectangle ? rectangle(rect, size: size) : ellipse(rect, size: size)
    }

    public static func rectangle(_ rect: CGRect, size: PixelSize) -> Self {
        make(rect, size: size, ellipse: false)
    }
    public static func ellipse(_ rect: CGRect, size: PixelSize) -> Self {
        make(rect, size: size, ellipse: true)
    }
    private static func make(_ rect: CGRect, size: PixelSize, ellipse: Bool) -> Self {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.maxX.isFinite,
            rect.minY.isFinite, rect.maxY.isFinite, rect.width > 0, rect.height > 0
        else { return .empty(size: size) }
        // The original ellipse is rasterized, then clipped; clipping does not reshape it.
        let clipped = rect.intersection(CGRect(origin: .zero, size: size.cgSize))
        guard !clipped.isNull, !clipped.isEmpty else { return .empty(size: size) }
        var rows = [[Range<Int>]](repeating: [], count: size.height)
        for y in Int(floor(clipped.minY))..<Int(ceil(clipped.maxY)) {
            let centerY = Double(y) + 0.5
            guard centerY >= rect.minY, ellipse ? centerY <= rect.maxY : centerY < rect.maxY else { continue }
            var left = rect.minX
            var right = rect.maxX
            if ellipse {
                let normalized = (centerY - rect.midY) / (rect.height / 2)
                let radius = rect.width / 2 * sqrt(max(0, 1 - normalized * normalized))
                left = rect.midX - radius
                right = rect.midX + radius
            }
            let lower = Int(min(Double(size.width), max(0, ceil(left - 0.5))))
            // Ellipse includes centers on its boundary; rectangle uses half-open edges.
            let upperValue = ellipse ? floor(right - 0.5) + 1 : ceil(right - 0.5)
            let upper = Int(min(Double(size.width), max(0, upperValue)))
            if lower < upper { rows[y] = [lower..<upper] }
        }
        return Self(size: size, rows: rows)
    }

    public func spans(at y: Int) -> [Range<Int>] { rows.indices.contains(y) ? rows[y] : [] }
    public func contains(x: Int, y: Int) -> Bool { spans(at: y).contains { $0.contains(x) } }
    public func inverted() -> Self {
        let rows = rows.map { spans in
            var result: [Range<Int>] = []
            var start = 0
            for span in spans {
                if start < span.lowerBound { result.append(start..<span.lowerBound) }
                start = span.upperBound
            }
            if start < size.width { result.append(start..<size.width) }
            return result
        }
        return Self(size: size, rows: rows)
    }
    public func translated(dx: Int, dy: Int) -> Self {
        guard abs(Double(dx)) < Double(size.width), abs(Double(dy)) < Double(size.height) else {
            return .empty(size: size)
        }
        var result = [[Range<Int>]](repeating: [], count: size.height)
        for y in rows.indices where (0..<size.height).contains(y + dy) {
            for span in rows[y] {
                let lower = max(0, span.lowerBound + dx)
                let upper = min(size.width, span.upperBound + dx)
                if lower < upper { result[y + dy].append(lower..<upper) }
            }
        }
        return Self(size: size, rows: result)
    }

    public var description: String {
        guard let bounds else { return "Empty selection" }
        return "Selection: \(Int(bounds.width)) × \(Int(bounds.height)) px at \(Int(bounds.minX)), \(Int(bounds.minY))"
    }

    /// Pixel-edge boundary with horizontal runs, including holes and clipped edges. O(row spans).
    public func outline() -> CGPath {
        let path = CGMutablePath()
        func line(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
        }
        func exposed(_ spans: [Range<Int>], against neighbors: [Range<Int>], y: Int) {
            for span in spans {
                var start = span.lowerBound
                for other in neighbors {
                    if other.upperBound <= start { continue }
                    if other.lowerBound >= span.upperBound { break }
                    if other.lowerBound > start { line(start, y, other.lowerBound, y) }
                    start = max(start, min(span.upperBound, other.upperBound))
                }
                if start < span.upperBound { line(start, y, span.upperBound, y) }
            }
        }
        for y in rows.indices {
            for span in rows[y] {
                line(span.lowerBound, y, span.lowerBound, y + 1)
                line(span.upperBound, y, span.upperBound, y + 1)
            }
            exposed(rows[y], against: spans(at: y - 1), y: y)
            exposed(rows[y], against: spans(at: y + 1), y: y + 1)
        }
        return path
    }
}

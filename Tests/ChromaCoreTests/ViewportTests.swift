import CoreGraphics
import Testing

@testable import ChromaCore

struct ViewportTests {
    @Test func zoomClampsAndRejectsNonfiniteValues() {
        #expect(Viewport.clampedZoom(-10) == 0.01)
        #expect(Viewport.clampedZoom(90) == 32)
        #expect(Viewport.clampedZoom(.nan) == 1)
        #expect(Viewport.clampedZoom(.infinity) == 1)
    }

    @Test func fitAccountsForRetinaAndMargins() throws {
        let size = try PixelSize(width: 1200, height: 800)
        #expect(Viewport.fitZoom(image: size, viewport: CGSize(width: 648, height: 448), backingScale: 2) == 1)
        #expect(Viewport.fitZoom(image: size, viewport: CGSize(width: 648, height: 448), backingScale: 1) == 0.5)
        #expect(Viewport.fitZoom(image: size, viewport: .zero, backingScale: 2) == 1)
    }

    @Test func fitUsesLimitingAxisAndClampsTinyWindows() throws {
        let size = try PixelSize(width: 800, height: 400)
        #expect(Viewport.fitZoom(image: size, viewport: CGSize(width: 848, height: 148), backingScale: 1) == 0.25)
        #expect(Viewport.fitZoom(image: size, viewport: CGSize(width: 1, height: 1), backingScale: 1) == 0.01)
    }

    @Test func zoomKeepsAnchorStationary() {
        var viewport = Viewport()
        viewport.move(by: CGSize(width: 10, height: -20))
        viewport.setZoom(2, anchor: CGPoint(x: 100, y: 50))
        #expect(viewport.pan == CGPoint(x: -80, y: -90))
        #expect(!viewport.isFitting)
    }

    @Test func fitResetsPanAndEnablesResizeTracking() throws {
        var viewport = Viewport()
        viewport.move(by: CGSize(width: 500, height: -500))
        viewport.fit(
            image: try PixelSize(width: 100, height: 100), viewport: CGSize(width: 800, height: 600), backingScale: 2)
        #expect(viewport.pan == .zero)
        #expect(viewport.isFitting)
    }

    @Test func actualSizeUsesPhysicalPixels() throws {
        var viewport = Viewport()
        viewport.setZoom(1)
        let rect = viewport.imageRect(
            image: try PixelSize(width: 1000, height: 500), viewport: CGSize(width: 800, height: 600), backingScale: 2)
        #expect(rect == CGRect(x: 150, y: 175, width: 500, height: 250))
    }

    @Test func actualSizeDoesNotStretchOddDimensions() throws {
        var viewport = Viewport()
        viewport.setZoom(1)
        let rect = viewport.imageRect(
            image: try PixelSize(width: 1001, height: 501), viewport: CGSize(width: 800, height: 600), backingScale: 2)
        #expect(rect.width * 2 == 1001)
        #expect(rect.height * 2 == 501)
        #expect((rect.minX * 2).rounded() == rect.minX * 2)
        #expect((rect.minY * 2).rounded() == rect.minY * 2)
    }

    @Test func panRemainsReachableAndIgnoresNaN() throws {
        var viewport = Viewport()
        viewport.move(by: CGSize(width: 100_000, height: -100_000))
        viewport.constrain(
            image: try PixelSize(width: 100, height: 100), viewport: CGSize(width: 800, height: 600), backingScale: 1)
        #expect(viewport.pan == CGPoint(x: 418, y: -318))
        viewport.move(by: CGSize(width: Double.nan, height: 0))
        #expect(viewport.pan == CGPoint(x: 418, y: -318))
    }
}

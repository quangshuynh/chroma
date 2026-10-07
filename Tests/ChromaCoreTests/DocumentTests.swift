import CoreGraphics
import Foundation
import Testing

@testable import ChromaCore

struct DocumentTests {
    @Test(arguments: [(0, 10), (10, 0), (-1, 10), (Int.min, Int.min)])
    func rejectsNonpositiveDimensions(width: Int, height: Int) {
        #expect(throws: ImageError.invalidDimensions) { try PixelSize(width: width, height: height) }
    }

    @Test(arguments: [(16_385, 1), (1, 16_385), (8_000, 8_000), (Int.max, Int.max)])
    func rejectsOversizedDimensions(width: Int, height: Int) {
        #expect(throws: ImageError.imageTooLarge) { try PixelSize(width: width, height: height) }
    }

    @Test func acceptsBoundariesWithoutAllocation() throws {
        #expect(try PixelSize(width: 1, height: 1).width == 1)
        #expect(try PixelSize(width: 16_384, height: 1).width == 16_384)
        #expect(try PixelSize(width: 8_000, height: 4_000).height == 4_000)
    }

    @Test func transparentBlankHasZeroAlpha() throws {
        let image = try RasterSurface(size: PixelSize(width: 5, height: 7), background: .transparent)
        #expect(pixels(image.image).allSatisfy { $0 == 0 })
    }

    @Test func opaqueBlankIsWhite() throws {
        let image = try RasterSurface(size: PixelSize(width: 5, height: 7), background: .white)
        #expect(pixels(image.image).allSatisfy { $0 == 255 })
    }

    @Test func navigationDoesNotChangeDocumentPixels() throws {
        let document = try sampleDocument()
        let before = try ImageCodec.encode(document, format: .png)
        var viewport = Viewport()
        viewport.fit(image: document.size, viewport: CGSize(width: 800, height: 600), backingScale: 2)
        viewport.setZoom(16)
        viewport.move(by: CGSize(width: 40, height: -300))
        #expect(try ImageCodec.encode(document, format: .png) == before)
        #expect(document.size == (try PixelSize(width: 4, height: 2)))
    }
}

func pixels(_ image: CGImage) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    var result = [UInt8]()
    for y in 0..<image.height {
        result.append(contentsOf: data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * 4)])
    }
    return result
}

func sampleDocument() throws -> ImageDocument {
    // Asymmetric, non-square fixture catches rotations, flips, alpha loss, and color swaps.
    let bytes: [UInt8] = [
        255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 0, 0, 255, 255,
        255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255,
    ]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return ImageDocument(raster: try RasterSurface(normalizing: image))
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ChromaCore

struct ImageCodecTests {
    @Test func supportedFormatsMatchInstalledDecoders() {
        #expect(ImageCodec.supportedInputTypes.contains(.png))
        #expect(ImageCodec.supportedInputTypes.contains(.jpeg))
        #expect(ImageCodec.supportedInputTypes.contains(.tiff))
        #expect(ImageCodec.supportedInputTypes.contains(.heic))
        #expect(!ImageCodec.supportedInputTypes.contains(.gif))
    }

    @Test func pngRoundTripPreservesPixelsAndTransparency() throws {
        let original = try sampleDocument()
        let decoded = try ImageCodec.decode(data: ImageCodec.encode(original, format: .png))
        #expect(decoded.size == original.size)
        #expect(pixels(decoded.composite) == pixels(original.composite))
        #expect(pixels(decoded.composite)[7] == 128)
        #expect(pixels(decoded.composite)[11] == 0)
    }

    @Test func jpegFlattensTransparentPixelsToWhite() throws {
        let original = ImageDocument(
            raster: try RasterSurface(size: PixelSize(width: 32, height: 24), background: .transparent))
        let decoded = try ImageCodec.decode(data: ImageCodec.encode(original, format: .jpeg))
        #expect(decoded.size == original.size)
        #expect(pixels(decoded.composite).allSatisfy { $0 >= 254 })
        #expect(pixels(original.composite).allSatisfy { $0 == 0 })
    }

    @Test func partialAlphaUsesWhiteMatte() throws {
        let original = try sampleDocument()
        let flattened = try RasterSurface(normalizing: original.raster.flattenedOnWhite())
        #expect(Array(pixels(flattened.image)[4..<8]) == [127, 255, 127, 255])
    }

    @Test(arguments: [UTType.tiff, .heic])
    func additionalInputsDecodeAtOriginalDimensions(type: UTType) throws {
        let original = ImageDocument(
            raster: try RasterSurface(size: PixelSize(width: 48, height: 32), background: .white))
        let encoded = try fixture(image: original.composite, type: type)
        let decoded = try ImageCodec.decode(data: encoded)
        #expect(decoded.size == original.size)
        #expect(pixels(decoded.composite).allSatisfy { $0 >= 250 })
    }

    @Test func tiffPreservesAlpha() throws {
        let original = try sampleDocument()
        let decoded = try ImageCodec.decode(data: fixture(image: original.composite, type: .tiff))
        #expect(pixels(decoded.composite) == pixels(original.composite))
    }

    @Test(arguments: [2, 3, 4, 5, 6, 7, 8])
    func appliesEXIFOrientation(orientation: Int) throws {
        let original = try sampleDocument()
        let data = try fixture(
            image: original.composite, type: .tiff, properties: [kCGImagePropertyOrientation: orientation])
        let decoded = try ImageCodec.decode(data: data)
        let swapsAxes = orientation >= 5
        #expect(decoded.size.width == (swapsAxes ? 2 : 4))
        #expect(decoded.size.height == (swapsAxes ? 4 : 2))
        let originalPixels = pixels(original.composite)
        let maps = [
            2: [3, 2, 1, 0, 7, 6, 5, 4], 3: [7, 6, 5, 4, 3, 2, 1, 0],
            4: [4, 5, 6, 7, 0, 1, 2, 3], 5: [0, 4, 1, 5, 2, 6, 3, 7],
            6: [4, 0, 5, 1, 6, 2, 7, 3], 7: [7, 3, 6, 2, 5, 1, 4, 0],
            8: [3, 7, 2, 6, 1, 5, 0, 4],
        ]
        let expected = maps[orientation]!.flatMap { Array(originalPixels[($0 * 4)..<($0 * 4 + 4)]) }
        #expect(pixels(decoded.composite) == expected)
    }

    @Test func rejectsInvalidData() {
        #expect(throws: ImageError.unreadableImage) { try ImageCodec.decode(data: Data("not an image".utf8)) }
    }

    @Test func rejectsUnsupportedGIF() throws {
        let data = try fixture(image: sampleDocument().composite, type: .gif)
        #expect(throws: ImageError.unsupportedFormat) { try ImageCodec.decode(data: data) }
    }

    @Test func rejectsTruncatedPNG() throws {
        let data = try ImageCodec.encode(sampleDocument(), format: .png)
        #expect(throws: (any Error).self) { try ImageCodec.decode(data: data.prefix(data.count / 2)) }
    }

    @Test func rejectsHugeDimensionsBeforeDecode() throws {
        // Patch the PNG header and its CRC without allocating a huge raster.
        var data = try ImageCodec.encode(sampleDocument(), format: .png)
        data.replaceSubrange(16..<20, with: [0, 0, 0x4e, 0x20])  // 20,000 pixels
        var crc: UInt32 = 0xffff_ffff
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        crc ^= 0xffff_ffff
        data.replaceSubrange(29..<33, with: (0..<4).map { UInt8(truncatingIfNeeded: crc >> (24 - $0 * 8)) })
        #expect(throws: ImageError.imageTooLarge) { try ImageCodec.decode(data: data) }
    }

    @Test func rejectsOversizedFileBeforeReadingBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImageCodec.maximumFileBytes + 1))
        try handle.close()
        #expect(throws: ImageError.imageTooLarge) { try ImageCodec.decode(url: url) }
    }

    @Test func fileExportRoundTripAndFailedWritePreserveSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let original = try sampleDocument()
        try ImageCodec.export(original, to: url, format: .png)
        let sourceBytes = try Data(contentsOf: url)
        let decoded = try ImageCodec.decode(url: url)
        #expect(pixels(decoded.composite) == pixels(original.composite))
        #expect(throws: (any Error).self) {
            try ImageCodec.export(original, to: directory.appendingPathComponent("missing/file.jpg"), format: .jpeg)
        }
        #expect(try Data(contentsOf: url) == sourceBytes)
        #expect(throws: (any Error).self) {
            try ImageCodec.decode(url: directory.appendingPathComponent("missing.png"))
        }
        #expect(throws: ImageError.unreadableImage) { try ImageCodec.decode(url: directory) }
    }
}

private func fixture(image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

import CoreGraphics
import Foundation

public enum ImageError: LocalizedError, Equatable {
    case invalidDimensions
    case imageTooLarge
    case unsupportedFormat
    case unreadableImage
    case allocationFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Enter whole-number dimensions greater than zero."
        case .imageTooLarge:
            "This image is too large. Use dimensions up to 16,384 pixels per side and 32 million pixels total, and a file under 256 MB."
        case .unsupportedFormat: "This file format is not supported. Choose a PNG, JPEG, TIFF, or HEIC image."
        case .unreadableImage: "The image could not be read. It may be incomplete or damaged."
        case .allocationFailed: "There is not enough memory to create this image. Try a smaller image."
        case .encodingFailed: "The image could not be encoded. Try saving to another location."
        }
    }
}

public struct PixelSize: Equatable, Sendable {
    public static let maximumDimension = 16_384
    public static let maximumPixelCount = 32_000_000
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ImageError.invalidDimensions }
        guard width <= Self.maximumDimension, height <= Self.maximumDimension,
            width <= Self.maximumPixelCount / height
        else { throw ImageError.imageTooLarge }
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

public enum ImageBackground: String, CaseIterable, Sendable {
    case transparent = "Transparent"
    case white = "White"
}

/// Immutable, owned, 8-bit premultiplied RGBA pixels in sRGB. Views never own or mutate this storage.
/// CGImage retains the bitmap snapshot; copying this value does not copy its pixels.
public struct RasterSurface: Sendable {
    public let size: PixelSize
    public let image: CGImage

    public init(size: PixelSize, background: ImageBackground) throws {
        let context = try Self.makeContext(size: size)
        if background == .white {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size.cgSize))
        }
        guard let image = context.makeImage() else { throw ImageError.allocationFailed }
        self.size = size
        self.image = image
    }

    public init(normalizing image: CGImage) throws {
        let size = try PixelSize(width: image.width, height: image.height)
        let context = try Self.makeContext(size: size)
        context.draw(image, in: CGRect(origin: .zero, size: size.cgSize))
        guard let normalized = context.makeImage() else { throw ImageError.allocationFailed }
        self.size = size
        self.image = normalized
    }

    public func flattenedOnWhite() throws -> CGImage {
        let context = try Self.makeContext(size: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(origin: .zero, size: size.cgSize)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ImageError.allocationFailed }
        return result
    }

    /// Exact canonical bytes, without row padding. Used by the compositor and native codec.
    public var rgbaBytes: Data {
        let data = image.dataProvider!.data! as Data
        if image.bytesPerRow == size.width * 4 { return data.prefix(size.width * size.height * 4) }
        var result = Data(capacity: size.width * size.height * 4)
        for y in 0..<size.height {
            result.append(data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + size.width * 4)])
        }
        return result
    }

    public init(size: PixelSize, premultipliedRGBA bytes: Data) throws {
        guard bytes.count == size.width * size.height * 4 else { throw LayerError.invalidRaster }
        let valid = bytes.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = pixels[offset + 3]
                if pixels[offset] > alpha || pixels[offset + 1] > alpha || pixels[offset + 2] > alpha { return false }
            }
            return true
        }
        guard valid, let provider = CGDataProvider(data: bytes as CFData),
            let image = CGImage(
                width: size.width, height: size.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: size.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw LayerError.invalidRaster }
        self.size = size
        self.image = image
    }

    private static func makeContext(size: PixelSize) throws -> CGContext {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: size.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ImageError.allocationFailed }
        return context
    }
}

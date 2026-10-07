import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    public var type: UTType { self == .png ? .png : .jpeg }
}

public enum ImageCodec {
    public static let maximumFileBytes = 256_000_000
    private static let requestedTypes: [UTType] = [.png, .jpeg, .tiff, .heic]
    public static var supportedInputTypes: [UTType] {
        let installed = CGImageSourceCopyTypeIdentifiers() as! [String]
        return requestedTypes.filter { installed.contains($0.identifier) }
    }

    public static func decode(url: URL) throws -> ImageDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ImageError.unreadableImage }
        guard let bytes = values.fileSize, bytes <= maximumFileBytes else { throw ImageError.imageTooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageError.unreadableImage }
        var document = try decode(source: source)
        let sourceName = String(url.deletingPathExtension().lastPathComponent.prefix(255))
        if !sourceName.isEmpty { _ = try? document.apply(.rename(document.activeLayerID, sourceName)) }
        return document
    }

    public static func decode(data: Data) throws -> ImageDocument {
        guard data.count <= maximumFileBytes else { throw ImageError.imageTooLarge }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageError.unreadableImage }
        return try decode(source: source)
    }

    private static func decode(source: CGImageSource) throws -> ImageDocument {
        guard let type = CGImageSourceGetType(source) as String? else { throw ImageError.unreadableImage }
        guard supportedInputTypes.contains(where: { $0.identifier == type })
        else { throw ImageError.unsupportedFormat }
        let index = type == UTType.heic.identifier ? CGImageSourceGetPrimaryImageIndex(source) : 0
        guard CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageError.unreadableImage }
        _ = try PixelSize(width: width, height: height)
        // ImageIO applies all eight EXIF orientations once, at original pixel resolution.
        // No embedded thumbnail is used, and navigation never re-decodes the source.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
            CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
        else { throw ImageError.unreadableImage }
        return ImageDocument(raster: try RasterSurface(normalizing: image))
    }

    public static func encode(_ document: ImageDocument, format: ExportFormat) throws -> Data {
        let raster = try LayerCompositor.composite(document)
        let image = try format == .jpeg ? raster.flattenedOnWhite() : raster.image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil)
        else { throw ImageError.encodingFailed }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        return data as Data
    }

    /// Atomic replacement prevents a failed encode/write from partially truncating an existing file.
    /// The caller must obtain a destination through a user-confirmed save panel.
    public static func export(_ document: ImageDocument, to url: URL, format: ExportFormat) throws {
        try encode(document, format: format).write(to: url, options: .atomic)
    }
}

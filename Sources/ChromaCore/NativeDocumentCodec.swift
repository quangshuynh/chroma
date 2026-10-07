import Foundation
import UniformTypeIdentifiers

public enum NativeDocumentError: LocalizedError, Equatable {
    case malformed
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .malformed:
            "This Chroma document is incomplete or damaged. Its manifest and layer files must form a valid versioned package."
        case .unsupportedVersion(let version):
            "Chroma document version \(version) is not supported by this version of Chroma."
        }
    }
}

/// Inspectable package: a JSON manifest plus exact, tightly packed premultiplied RGBA files.
/// PNG is intentionally not the authoritative layer encoding: unpremultiply/re-premultiply
/// conversions can change low-alpha channel bytes. Raw RGBA preserves every working byte.
public enum NativeDocumentCodec {
    public static let type = UTType(exportedAs: "com.chroma.editor.document", conformingTo: .package)
    public static let fileExtension = "chroma"
    public static let version = 1
    private static let maximumManifestBytes = 1_000_000

    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let width: Int
        let height: Int
        let pixelFormat: String
        let layers: [LayerRecord]
    }
    private struct LayerRecord: Codable {
        let id: UUID
        let name: String
        let visible: Bool
        let opacity: Double
        var filename: String { id.uuidString + ".rgba" }
    }
    private static let pixelFormat = "rgba8-premultiplied-srgb"

    public static func fileWrapper(for document: ImageDocument) throws -> FileWrapper {
        let manifest = Manifest(
            version: version, id: document.id, width: document.size.width,
            height: document.size.height, pixelFormat: pixelFormat,
            layers: document.layers.map {
                LayerRecord(id: $0.id, name: $0.name, visible: $0.isVisible, opacity: $0.opacity)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files: [String: FileWrapper] = [:]
        for (record, layer) in zip(manifest.layers, document.layers) {
            files[record.filename] = FileWrapper(regularFileWithContents: layer.raster.rgbaBytes)
        }
        return FileWrapper(directoryWithFileWrappers: [
            "document.json": FileWrapper(regularFileWithContents: try encoder.encode(manifest)),
            "layers": FileWrapper(directoryWithFileWrappers: files),
        ])
    }

    public static func decode(_ package: FileWrapper) throws -> ImageDocument {
        guard package.isDirectory, let root = package.fileWrappers,
            Set(root.keys) == ["document.json", "layers"],
            let json = root["document.json"], json.isRegularFile, let data = json.regularFileContents,
            let directory = root["layers"], directory.isDirectory, let files = directory.fileWrappers
        else { throw NativeDocumentError.malformed }
        let manifest = try manifest(from: data)
        guard Set(files.keys) == Set(manifest.layers.map(\.filename)) else { throw NativeDocumentError.malformed }
        return try build(manifest) { record, byteCount in
            guard let file = files[record.filename], file.isRegularFile,
                let bytes = file.regularFileContents, bytes.count == byteCount
            else { throw NativeDocumentError.malformed }
            return bytes
        }
    }

    /// Read only the validated manifest and the exact UUID-derived filenames, with size checks
    /// before allocation. Reject symlinks and unexpected package entries, including nested paths.
    public static func read(from url: URL) throws -> ImageDocument {
        try requireDirectory(url, entries: ["document.json", "layers"])
        let data = try readRegular(url.appendingPathComponent("document.json"), maximum: maximumManifestBytes)
        let manifest = try manifest(from: data)
        let layersURL = url.appendingPathComponent("layers", isDirectory: true)
        try requireDirectory(layersURL, entries: Set(manifest.layers.map(\.filename)))
        return try build(manifest) { record, byteCount in
            let data = try readRegular(layersURL.appendingPathComponent(record.filename), maximum: byteCount)
            guard data.count == byteCount else { throw NativeDocumentError.malformed }
            return data
        }
    }

    private static func manifest(from data: Data) throws -> Manifest {
        guard data.count <= maximumManifestBytes else { throw NativeDocumentError.malformed }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch {
            throw NativeDocumentError.malformed
        }
        guard manifest.version == version else { throw NativeDocumentError.unsupportedVersion(manifest.version) }
        guard manifest.pixelFormat == pixelFormat,
            let size = try? PixelSize(width: manifest.width, height: manifest.height),
            ImageDocument.acceptsLayerCount(manifest.layers.count, size: size),
            Set(manifest.layers.map(\.id)).count == manifest.layers.count,
            manifest.layers.allSatisfy({ $0.opacity.isFinite && (0...1).contains($0.opacity) })
        else { throw NativeDocumentError.malformed }
        return manifest
    }

    private static func build(_ manifest: Manifest, read: (LayerRecord, Int) throws -> Data) throws -> ImageDocument {
        do {
            let size = try PixelSize(width: manifest.width, height: manifest.height)
            let layers = try manifest.layers.map { record in
                let raster = try RasterSurface(
                    size: size, premultipliedRGBA: read(record, size.width * size.height * 4))
                let layer = try RasterLayer(
                    id: record.id, name: record.name, raster: raster,
                    isVisible: record.visible, opacity: record.opacity)
                guard layer.name == record.name else { throw NativeDocumentError.malformed }
                return layer
            }
            return try ImageDocument(id: manifest.id, size: size, layers: layers)
        } catch { throw NativeDocumentError.malformed }
    }

    private static func requireDirectory(_ url: URL, entries: Set<String>) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
            Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == entries
        else { throw NativeDocumentError.malformed }
    }

    private static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let count = values.fileSize, count <= maximum
        else { throw NativeDocumentError.malformed }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw NativeDocumentError.malformed }
        return data
    }
}

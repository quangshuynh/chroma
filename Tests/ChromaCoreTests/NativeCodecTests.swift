import Foundation
import Testing

@testable import ChromaCore

struct NativeCodecTests {
    @Test func packageRoundTripPreservesEveryPersistentFieldAndPixel() throws {
        var doc = try layeredFixture()
        try doc.apply(.visibility(doc.layers[1].id, false))
        try doc.apply(.rename(doc.layers[0].id, "底色 🎨"))
        try doc.apply(.move(doc.layers[2].id, to: 0))
        try doc.selectLayer(doc.layers[0].id)
        let wrapper = try NativeDocumentCodec.fileWrapper(for: doc)
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let reopened = try NativeDocumentCodec.read(from: url)
        try expectSameContent(doc, reopened)
        #expect(reopened.activeLayerID == reopened.layers.last?.id)
        #expect(reopened.activeLayerID != doc.activeLayerID)
        try expectSameContent(doc, NativeDocumentCodec.decode(wrapper))
        let second = try NativeDocumentCodec.fileWrapper(for: reopened)
        #expect(
            wrapper.fileWrappers?["document.json"]?.regularFileContents
                == second.fileWrappers?["document.json"]?.regularFileContents)
    }

    @Test func rawPixelsPreserveAllLowAlphaValuesExactly() throws {
        var bytes = Data()
        for alpha in 0...255 {
            bytes.append(contentsOf: [UInt8(alpha / 3), UInt8(alpha / 2), UInt8(alpha), UInt8(alpha)])
        }
        let surface = try RasterSurface(size: PixelSize(width: 256, height: 1), premultipliedRGBA: bytes)
        let doc = ImageDocument(raster: surface)
        let decoded = try NativeDocumentCodec.decode(NativeDocumentCodec.fileWrapper(for: doc))
        #expect(decoded.layers[0].raster.rgbaBytes == bytes)
    }

    @Test(arguments: [
        "version", "dimensions", "empty", "duplicates", "opacity", "name", "pixelFormat", "path", "missingField",
    ])
    func rejectsMalformedManifest(kind: String) throws {
        let wrapper = try NativeDocumentCodec.fileWrapper(for: layeredFixture())
        try mutateManifest(wrapper) { manifest in
            var layers = manifest["layers"] as! [[String: Any]]
            switch kind {
            case "version": manifest["version"] = 99
            case "dimensions": manifest["width"] = Int.max
            case "empty": layers = []
            case "duplicates": layers[1]["id"] = layers[0]["id"]
            case "opacity": layers[0]["opacity"] = -1
            case "name": layers[0]["name"] = " "
            case "pixelFormat": manifest["pixelFormat"] = "other"
            case "path": layers[0]["id"] = "../../outside"
            case "missingField": manifest.removeValue(forKey: "height")
            default: break
            }
            manifest["layers"] = layers
        }
        if kind == "version" {
            #expect(throws: NativeDocumentError.unsupportedVersion(99)) { try NativeDocumentCodec.decode(wrapper) }
        } else {
            #expect(throws: NativeDocumentError.malformed) { try NativeDocumentCodec.decode(wrapper) }
        }
    }

    @Test(arguments: ["missing", "truncated", "extra", "symlink", "directory", "invalidAlpha"])
    func rejectsMalformedLayerFiles(kind: String) throws {
        let doc = try layeredFixture()
        let wrapper = try NativeDocumentCodec.fileWrapper(for: doc)
        let layers = wrapper.fileWrappers!["layers"]!
        let name = doc.layers[0].id.uuidString + ".rgba"
        let original = layers.fileWrappers![name]!
        layers.removeFileWrapper(original)
        switch kind {
        case "truncated": add(FileWrapper(regularFileWithContents: Data([0])), named: name, to: layers)
        case "extra":
            add(original, named: name, to: layers)
            add(FileWrapper(regularFileWithContents: Data()), named: "extra.rgba", to: layers)
        case "symlink":
            add(
                FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/tmp/outside")), named: name,
                to: layers)
        case "directory": add(FileWrapper(directoryWithFileWrappers: [:]), named: name, to: layers)
        case "invalidAlpha": add(FileWrapper(regularFileWithContents: Data([255, 0, 0, 0])), named: name, to: layers)
        default: break
        }
        #expect(throws: NativeDocumentError.malformed) { try NativeDocumentCodec.decode(wrapper) }
    }

    @Test func rejectsInvalidJSONAndOversizedManifest() throws {
        for data in [Data("{".utf8), Data(repeating: 32, count: 1_000_001)] {
            let wrapper = FileWrapper(directoryWithFileWrappers: [
                "document.json": FileWrapper(regularFileWithContents: data),
                "layers": FileWrapper(directoryWithFileWrappers: [:]),
            ])
            #expect(throws: NativeDocumentError.malformed) { try NativeDocumentCodec.decode(wrapper) }
        }
    }

    @Test(arguments: ["root", "layers", "manifest", "raster"])
    func diskReadRejectsSymlinks(location: String) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let doc = try layeredFixture()
        let package = parent.appendingPathComponent("Artwork.chroma")
        try NativeDocumentCodec.fileWrapper(for: doc).write(to: package, options: .atomic, originalContentsURL: nil)
        let target: URL
        switch location {
        case "root": target = package
        case "layers": target = package.appendingPathComponent("layers")
        case "manifest": target = package.appendingPathComponent("document.json")
        default: target = package.appendingPathComponent("layers/\(doc.layers[0].id.uuidString).rgba")
        }
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: target, to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        #expect(throws: NativeDocumentError.malformed) { try NativeDocumentCodec.read(from: package) }
    }

    @Test func diskReadRejectsOversizedLayerBeforeAllocation() throws {
        let doc = try layeredFixture()
        let package = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try NativeDocumentCodec.fileWrapper(for: doc).write(to: package, options: .atomic, originalContentsURL: nil)
        let raster = package.appendingPathComponent("layers/\(doc.layers[0].id.uuidString).rgba")
        let handle = try FileHandle(forWritingTo: raster)
        try handle.truncate(atOffset: 1_000_000_000)
        try handle.close()
        #expect(throws: NativeDocumentError.malformed) { try NativeDocumentCodec.read(from: package) }
    }

    @Test func importedFilenameNamesInitialLayer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Sunset.png")
        try ImageCodec.export(sampleDocument(), to: url, format: .png)
        let imported = try ImageCodec.decode(url: url)
        #expect(imported.activeLayer.name == "Sunset")
        #expect(imported.layers.count == 1)
    }
}

private func expectSameContent(_ lhs: ImageDocument, _ rhs: ImageDocument) throws {
    #expect(lhs.id == rhs.id)
    #expect(lhs.size == rhs.size)
    #expect(lhs.layers.count == rhs.layers.count)
    #expect(lhs.layers.map(\.id) == rhs.layers.map(\.id))
    for (a, b) in zip(lhs.layers, rhs.layers) {
        #expect(a.name == b.name)
        #expect(a.isVisible == b.isVisible)
        #expect(a.opacity == b.opacity)
        #expect(a.raster.rgbaBytes == b.raster.rgbaBytes)
    }
    #expect(try compositeBytes(lhs) == compositeBytes(rhs))
}

private func temporaryPackage() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chroma")
}

private func mutateManifest(_ wrapper: FileWrapper, edit: (inout [String: Any]) -> Void) throws {
    let original = wrapper.fileWrappers!["document.json"]!
    var manifest = try JSONSerialization.jsonObject(with: original.regularFileContents!) as! [String: Any]
    edit(&manifest)
    wrapper.removeFileWrapper(original)
    add(
        FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: manifest)),
        named: "document.json", to: wrapper)
}

private func add(_ wrapper: FileWrapper, named name: String, to directory: FileWrapper) {
    wrapper.preferredFilename = name
    directory.addFileWrapper(wrapper)
}

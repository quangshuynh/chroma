import AppKit
import ChromaCore

/// Private canonical bytes preserve low alpha exactly between Chroma documents. PNG is the
/// interoperable representation; external PNG/TIFF goes through the bounded ImageIO decoder.
@MainActor
enum RasterClipboard {
    static let canonical = NSPasteboard.PasteboardType("com.chroma.raster-rgba-v1")
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [canonical, .png, .tiff]) != nil
    }
    static func write(_ raster: RasterSurface, to pasteboard: NSPasteboard) throws -> Bool {
        let png = try ImageCodec.encode(ImageDocument(raster: raster), format: .png)
        var exact = Data()
        for value in [UInt32(raster.size.width), UInt32(raster.size.height)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { exact.append(contentsOf: $0) }
        }
        exact.append(raster.rgbaBytes)
        let item = NSPasteboardItem()
        guard item.setData(exact, forType: canonical), item.setData(png, forType: .png) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
    static func read(from pasteboard: NSPasteboard) throws -> RasterSurface? {
        if let data = pasteboard.data(forType: canonical), data.count >= 8 {
            func integer(_ offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
            }
            let size = try PixelSize(width: integer(0), height: integer(4))
            guard data.count == 8 + size.width * size.height * 4 else { throw LayerError.invalidRaster }
            return try RasterSurface(size: size, premultipliedRGBA: Data(data.dropFirst(8)))
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return try ImageCodec.decode(data: data).activeLayer.raster }
        }
        return nil
    }
}

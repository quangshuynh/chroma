import Foundation

/// Normal source-over in the existing encoded sRGB working space, premultiplied RGBA.
/// Each layer rounds once to 8-bit (nearest, ties away from zero). No UI state enters here.
public enum LayerCompositor {
    public static func composite(_ document: ImageDocument) throws -> RasterSurface {
        let visible = document.layers.filter { $0.isVisible && $0.opacity > 0 }
        // Import and a single untouched layer retain the original full-resolution allocation.
        if visible.count == 1, visible[0].opacity == 1 { return visible[0].raster }
        var result = Data(count: document.size.width * document.size.height * 4)
        result.withUnsafeMutableBytes { rawOutput in
            let output = rawOutput.bindMemory(to: UInt8.self)
            for layer in visible {
                layer.raster.rgbaBytes.withUnsafeBytes { rawInput in
                    let input = rawInput.bindMemory(to: UInt8.self)
                    for offset in stride(from: 0, to: output.count, by: 4) {
                        let remaining = 1 - Double(input[offset + 3]) / 255 * layer.opacity
                        for channel in 0..<4 {
                            let value =
                                Double(input[offset + channel]) * layer.opacity + Double(output[offset + channel])
                                * remaining
                            output[offset + channel] = UInt8(min(255, max(0, value.rounded())))
                        }
                    }
                }
            }
        }
        return try RasterSurface(size: document.size, premultipliedRGBA: result)
    }
    /// Integer, clipped document region. Used for transient painting previews.
    static func compositeRegion(
        _ document: ImageDocument, rect: CGRect, replacing id: UUID, bytes: Data, replacementRect: CGRect? = nil
    ) throws
        -> RasterSurface
    {
        let width = Int(rect.width)
        let height = Int(rect.height)
        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes { rawOutput in
            let output = rawOutput.bindMemory(to: UInt8.self)
            for layer in document.layers where layer.isVisible && layer.opacity > 0 {
                let data = layer.id == id ? bytes : layer.raster.rgbaBytes
                data.withUnsafeBytes { rawInput in
                    let input = rawInput.bindMemory(to: UInt8.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let src = ((Int(rect.minY) + y) * document.size.width + Int(rect.minX) + x) * 4
                            let dst = (y * width + x) * 4
                            let sourceOffset: Int
                            if layer.id == id, let replacementRect {
                                sourceOffset =
                                    ((Int(rect.minY) + y - Int(replacementRect.minY)) * Int(replacementRect.width)
                                        + Int(rect.minX) + x - Int(replacementRect.minX)) * 4
                            } else {
                                sourceOffset = src
                            }
                            let remaining = 1 - Double(input[sourceOffset + 3]) / 255 * layer.opacity
                            for channel in 0..<4 {
                                output[dst + channel] = UInt8(
                                    min(
                                        255,
                                        max(
                                            0,
                                            (Double(input[sourceOffset + channel]) * layer.opacity
                                                + Double(output[dst + channel]) * remaining).rounded())))
                            }
                        }
                    }
                }
            }
        }
        return try RasterSurface(size: PixelSize(width: width, height: height), premultipliedRGBA: result)
    }

}

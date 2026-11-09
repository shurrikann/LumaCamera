import CoreImage
import UIKit

/// Immutable, predecoded sRGB colour table shared by preview, thumbnails and photo rendering.
/// Cube entries are RGBA Float32, ordered red-fastest, then green, then blue.
struct FilmColorLUT {
    let dimension: Int
    let data: Data?
    static let m9 = FilmColorLUT(assetName: "FilmLUT-M9", dimension: 64)

    init(dimension: Int, bytes: Data) {
        self.dimension = dimension
        self.data = (2...64).contains(dimension) && bytes.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size ? bytes : nil
    }

    init(assetName: String, dimension: Int) {
        self.dimension = dimension
        guard (2...64).contains(dimension),
              let bytes = NSDataAsset(name: assetName)?.data,
              bytes.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size else {
            data = nil
            return
        }
        data = bytes
    }

    func apply(to image: CIImage) -> CIImage {
        guard let data else { return image }
        // SDR 目录里的 LUT 均按 Rec.709 显示色彩空间制作，不是 LogC/Cineon。
        let cubeColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
            "inputColorSpace": cubeColorSpace,
            "inputExtrapolate": true
        ]).cropped(to: image.extent)
    }
}

import Foundation
import CoreImage

/// HDR预览与成片共用的软肩参数。
enum HDRToneMapping {
    static let knee: Float = 0.8
    static let headroom: Float = 4.0
    static let previewMaxGain: Float = 3.0

    /// 编码标记描述实际输出像素，不用固定headroom代替测量，也不改变曝光。
    static func measuredHeadroom(_ image: CIImage, context: CIContext) -> Float {
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(maximum, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        }
        let peak = pixel.prefix(3).max() ?? 1
        return peak.isFinite ? max(1, peak) : headroom
    }
}

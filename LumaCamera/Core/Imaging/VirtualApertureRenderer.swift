import CoreImage
import Foundation
import ImageIO

/// 软件星芒，不改变真实快门/ISO/景深或EXIF物理光圈。仅从高亮局部峰值生成八向渐隐光线。
enum VirtualApertureRenderer {
    static let minimum = 1.4, maximum = 16.0, defaultValue = 5.6
    private static let seeds = MetalImageKernels.general("aperturePointSeeds")
    private static let add = MetalImageKernels.color("apertureStarAdd")
    static var available: Bool { seeds != nil && add != nil }
    static func clamped(_ value: Double) -> Double { value.isFinite ? min(max(value, minimum), maximum) : defaultValue }
    static func value(at position: Double) -> Double { minimum * pow(maximum / minimum, min(max(position, 0), 1)) }
    static func position(for value: Double) -> Double { log(clamped(value) / minimum) / log(maximum / minimum) }
    static func apply(_ input: CIImage, fNumber: Double?) -> CIImage {
        guard let fNumber, let seeds, let add else { return input }
        // 将整段连续范围压缩：新ƒ/16对应上一版ƒ/6的半径和亮度，预览/成片共用。
        let amount = pow(position(for: fNumber) * position(for: 6.0), 2)
        guard amount > 0.00001 else { return input }
        let extent = input.extent
        let scale = min(1, 384 / max(extent.width, extent.height))
        // 缩图前保留小光源峰值，避免远处LED在降采样后低于阈值而完全没有星芒。
        let peaks = scale < 1 ? input.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: min(5, 0.5 / scale)]).cropped(to: extent) : input
        let small = peaks.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blur = small.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3]).cropped(to: small.extent)
        // 两圈邻域检查亮区是否向外延伸；灯板边缘、角点及长亮线不作为孤立点光源。
        // 按画面尺寸归一化阈值，预览与成片采用同样的相对空间范围。
        let isolationRadius = max(small.extent.width, small.extent.height) * 0.035
        guard let bright = seeds.apply(extent: small.extent, roiCallback: { index, rect in
            index == 0 ? rect.insetBy(dx: -isolationRadius * 1.45 - 2, dy: -isolationRadius * 1.45 - 2) : rect
        }, arguments: [small.clampedToExtent(), blur, isolationRadius]) else { return input }
        var rays = CIImage(color: .black).cropped(to: small.extent)
        let radius = min(small.extent.width, small.extent.height) * (0.025 + 0.095 * amount)
        // 每个方向只做一次模糊，避免原先12次模糊与12次矩阵图的重复开销。
        // 模糊本身按长度平均亮度，合成时补偿能量，使小光源也能形成可见光线。
        for angle in [0.0, Double.pi / 4, Double.pi / 2, Double.pi * 3 / 4] {
            let ray = bright.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angle])
                .cropped(to: small.extent)
            rays = add.apply(extent: small.extent, arguments: [rays, ray, 1.0]) ?? rays
        }
        let enlarged = rays.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return (add.apply(extent: extent, arguments: [input, enlarged, amount * 7.0]) ?? input).settingProperties(input.properties)
    }
    static func label(_ value: Double) -> String { String(format: "ƒ/%.1f", clamped(value)) }
    static func recordedValue(_ properties: [CFString: Any]) -> Double? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        guard let comment = exif?[kCGImagePropertyExifUserComment] as? String,
              let token = comment.components(separatedBy: "LumaCamera.VirtualAperture=").last,
              comment.contains("LumaCamera.VirtualAperture="), let value = Double(token.split(whereSeparator: { $0.isWhitespace }).first ?? ""),
              value >= minimum, value <= maximum else { return nil }
        return value
    }
}

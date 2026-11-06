import CoreImage

enum PhotoTone: String, CaseIterable, Identifiable {
    case natural = "自然影调", cinematic = "电影质感", contrast = "高对比度", bright = "清新明亮"
    var id: String { rawValue }
    private static let kernel = MetalImageKernels.color("proTone")
    /// Five perceptual luminance knots at 0, 0.25, 0.5, 0.75 and 1.
    /// Natural retains the RAW development's neutral baseline.
    var curve: [Double] {
        switch self {
        case .natural: return [0, 0.25, 0.5, 0.75, 1]
        case .cinematic: return [0.055, 0.30, 0.515, 0.735, 0.94]
        case .contrast: return [0, 0.10, 0.35, 0.72, 1]
        case .bright: return [0.04, 0.38, 0.62, 0.82, 1]
        }
    }
    var saturation: Double {
        switch self {
        case .natural: return 1
        case .cinematic: return 0.83
        case .contrast: return 1.04
        case .bright: return 0.86
        }
    }
    /// PQ高动态以RAW显影的黑位和中灰为基准。清新明亮在HDR下只轻抬中间调，
    /// 不沿用SDR参考样片中主动抬黑、降反差的配方；其他影调保持既有创作意图。
    private func outputCurve(hdr: Bool) -> [Double] {
        hdr && self == .bright ? [0, 0.30, 0.55, 0.79, 1] : curve
    }
    private func outputSaturation(hdr: Bool) -> Double {
        hdr && self == .bright ? 0.94 : saturation
    }
    func apply(to image: CIImage, hdr: Bool = false) -> CIImage {
        guard self != .natural else { return image }
        let values = outputCurve(hdr: hdr)
        return Self.kernel?.apply(extent: image.extent, arguments: [image,
            CIVector(x: values[0], y: values[1], z: values[2], w: values[3]), values[4], outputSaturation(hdr: hdr)]) ?? image
    }
}

enum CameraMetering: String, CaseIterable, Identifiable {
    case system = "系统测光", global = "全局测光", spot = "点测光"
    var id: String { rawValue }
    var icon: String { self == .system ? "camera.metering.multispot" : self == .global ? "camera.metering.center.weighted" : "camera.metering.spot" }
}

import CoreImage

enum PhotoTone: String, CaseIterable, Identifiable {
    case natural = "自然影调", cinematic = "电影质感", contrast = "高对比度", bright = "清新明亮"
    var id: String { rawValue }
    private static let kernel = MetalImageKernels.color("proTone")
    private static let cinematicKernel = MetalImageKernels.color("cinematicGrade")
    /// Five perceptual luminance knots at 0, 0.25, 0.5, 0.75 and 1.
    /// Natural retains the RAW development's neutral baseline.
    var curve: [Double] {
        switch self {
        case .natural: return [0, 0.25, 0.5, 0.75, 1]
        case .cinematic: return [0.004, 0.205, 0.482, 0.785, 0.975]
        case .contrast: return [0, 0.13, 0.38, 0.72, 1]
        case .bright: return [0.02, 0.38, 0.59, 0.82, 1]
        }
    }
    var saturation: Double {
        switch self {
        case .natural: return 1
        case .cinematic: return 1
        case .contrast: return 1.02
        case .bright: return 0.90
        }
    }
    /// HDR 电影质感减少抬黑，清新明亮收敛中间调。高对比共用暗部节点，
    /// 三种影调都在参考白附近逐渐回到 RAW 的亮度和色彩。
    private func outputCurve(hdr: Bool) -> [Double] {
        guard hdr else { return curve }
        switch self {
        case .cinematic: return [0.004, 0.205, 0.482, 0.785, 1]
        case .bright: return [0, 0.30, 0.55, 0.79, 1]
        case .natural, .contrast: return curve
        }
    }
    private func outputSaturation(hdr: Bool) -> Double {
        guard hdr else { return saturation }
        switch self {
        case .bright: return 0.94
        case .natural, .cinematic, .contrast: return saturation
        }
    }
    func apply(to image: CIImage, hdr: Bool = false) -> CIImage {
        guard self != .natural else { return image }
        let values = outputCurve(hdr: hdr)
        let toned = Self.kernel?.apply(extent: image.extent, arguments: [image,
            CIVector(x: values[0], y: values[1], z: values[2], w: values[3]),
            values[4], outputSaturation(hdr: hdr), Float(hdr ? 1 : 0)]) ?? image
        guard self == .cinematic, let grade = Self.cinematicKernel else { return toned }
        return grade.apply(extent: image.extent, arguments: [toned, Float(hdr ? 1 : 0)]) ?? toned
    }
}

enum CameraMetering: String, CaseIterable, Identifiable {
    case system = "系统测光"
    case centerWeighted = "中央重点"
    case spot = "点测光"
    case highlight = "高光保护"

    init?(storedValue: String) {
        self.init(rawValue: storedValue == "高光加权" ? Self.highlight.rawValue : storedValue)
    }

    var id: String { rawValue }
    var usesPreviewMetering: Bool { self == .centerWeighted || self == .highlight }
    var icon: String {
        switch self {
        case .system: "camera.metering.multispot"
        case .centerWeighted: "camera.metering.center.weighted"
        case .spot: "camera.metering.spot"
        case .highlight: "sun.max"
        }
    }
}

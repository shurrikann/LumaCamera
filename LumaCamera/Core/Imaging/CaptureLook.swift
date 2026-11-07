import Foundation

struct CaptureLook {
    var style: FilmStyle = .original
    var intensity: Double = 0.8
    var ratio: FrameRatio = .standard
    /// 前置动态构图，或后置快门时按物理持机方向确定的输出裁切轴。
    var landscape = false
    var grainPhase = 0.0
    var border = false
    var tone: PhotoTone = .natural
    var adjustments = FilterAdjustments()
    var virtualAperture: Double? = nil // nil为关闭；数值为软件星芒光圈，不是镜头物理光圈。
    var nightPreviewAssist = false // 仅实时取景显示，PhotoEncoder不应用。
    var requiresImageProcessing: Bool {
        // 非自然影调进入图像处理，HDR 成片可分别生成影调后的 SDR 和 HDR 图层。
        (style != .original && intensity > 0) || !adjustments.isNeutral || virtualAperture != nil || tone != .natural
    }
    func forOutput(_ format: PhotoFileFormat) -> CaptureLook {
        var result = self
        if format == .raw {
            result.style = .original
            result.intensity = 0
            result.adjustments = FilterAdjustments()
            // 原始 DNG 不套用应用裁切，宽高比切换只作用于可处理的成片。
            result.landscape = false
            result.virtualAperture = nil
        }
        return result
    }
}


import Foundation

/// 原生静态照片的曝光与采样计划；各预设的融合方式/持续时间独立，不把它们当作同一种滤镜。
struct AdaptiveSlowShutterExposurePlan {
    let iso: Double
    let spec: SlowShutterSequenceSpec
}

enum AdaptiveSlowShutterExposurePolicy {
    static func plan(preset: SlowShutterPreset, meteredISO: Double, meteredSeconds: Double,
                     hardwareISO: ClosedRange<Double>, hardwareShutter: ClosedRange<Double>,
                     manualISO: Double? = nil, manualSeconds: Double? = nil) -> AdaptiveSlowShutterExposurePlan? {
        guard var spec = preset.sequenceSpec,
              let shutterRange = preset.shutterRange(limitedTo:hardwareShutter),
              let exposure = AdaptiveWaterExposurePolicy.plan(meteredISO:meteredISO,meteredSeconds:meteredSeconds,
                isoRange:hardwareISO,shutterRange:shutterRange,manualISO:manualISO,manualSeconds:manualSeconds,
                preferredMaximumSeconds:manualSeconds == nil ? preset.handheldPreferredExposure : nil) else { return nil }
        spec.exposureOverride = exposure.seconds
        // totalDuration只表示采满帧上限时的累计曝光，终止条件以真实采样时间/最少帧/上限共同决定。
        spec = .init(frameCount:spec.frameCount,totalDuration:exposure.seconds*Double(spec.frameCount),
                     blend:spec.blend,exposureOverride:exposure.seconds,captureDuration:spec.captureDuration,
                     minimumFrames:spec.minimumFrames)
        return .init(iso:exposure.iso,spec:spec)
    }
}

extension SlowShutterPreset {
    /// 应用手持起点；保持测光曝光量，极暗环境在硬件ISO用尽后允许更长曝光。
    var handheldPreferredExposure:Double {
        switch self {
        case .silkyWater,.motionBlur,.panning: return 1.0/60
        case .lightTrails: return 1.0/30
        case .starTrails: return 0.5
        }
    }
}

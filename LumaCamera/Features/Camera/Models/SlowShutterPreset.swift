import Foundation

/// 五种慢门共享测光自适应，分别保留合适的单帧上限和时间融合方式。
enum SlowShutterPreset: String, CaseIterable, Identifiable, Codable {
    case lightTrails
    case silkyWater
    case motionBlur
    case panning
    case starTrails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lightTrails: return "光轨"
        case .silkyWater: return "流水"
        case .motionBlur: return "动态\n模糊"
        case .panning: return "摇拍\n追焦"
        case .starTrails: return "星轨"
        }
    }

    /// The useful single-frame shutter interval for each visual style.
    /// Hardware will clamp this to its actual exposure range.
    var shutterSeconds: ClosedRange<Double> {
        switch self {
        case .lightTrails: return 0.000001...1.0
        case .silkyWater: return 0.000001...1.0
        case .motionBlur: return 0.000001...0.25
        case .panning: return 0.000001...(1.0 / 15.0)
        case .starTrails: return 0.000001...1.0
        }
    }

    var suggestedShutterSeconds: Double {
        switch self {
        case .lightTrails: return 0.5
        case .silkyWater: return 0.5
        case .motionBlur: return 1.0 / 8.0
        case .panning: return 1.0 / 30.0
        case .starTrails: return 1.0
        }
    }

    var suggestedISORange: ClosedRange<Double> {
        switch self {
        case .lightTrails: return 50...200
        case .silkyWater: return 50...200
        case .motionBlur: return 50...400
        case .panning: return 50...800
        case .starTrails: return 100...800
        }
    }

    var suggestedISO: Double {
        switch self {
        case .lightTrails, .silkyWater: return 100
        case .motionBlur, .panning: return 200
        case .starTrails: return 400
        }
    }

    var shutterLog2Range: ClosedRange<Double> {
        log2(shutterSeconds.lowerBound)...log2(shutterSeconds.upperBound)
    }


    func shutterRange(limitedTo hardware: ClosedRange<Double>) -> ClosedRange<Double>? {
        Self.intersection(shutterLog2Range, hardware)
    }

    func isoRange(limitedTo hardware: ClosedRange<Double>) -> ClosedRange<Double>? {
        // 建议ISO不再作为硬限制；暗光下允许在镜头真实范围内提高ISO。
        hardware
    }

    /// UI-only M-mode range. The sequence planner still uses the full
    /// hardware ISO range for dark-scene metering.
    func manualISORange(limitedTo hardware: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lower = max(suggestedISORange.lowerBound, hardware.lowerBound)
        let upper = min(suggestedISORange.upperBound, hardware.upperBound)
        return lower < upper ? lower...upper : nil
    }

    func supports(hardwareShutter: ClosedRange<Double>, hardwareISO: ClosedRange<Double>) -> Bool {
        shutterRange(limitedTo: hardwareShutter) != nil && isoRange(limitedTo: hardwareISO) != nil
    }

    private static func intersection(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lower = max(lhs.lowerBound, rhs.lowerBound)
        let upper = min(lhs.upperBound, rhs.upperBound)
        // Avoid exposing a zero-width wheel when a format barely overlaps the
        // preset. If it cannot provide a useful interval, retain its real range.
        return lower < upper ? lower...upper : nil
    }
}

enum SlowShutterDuration: String, CaseIterable, Identifiable, Codable {
    case s03 = "0.3"
    case s05 = "0.5"
    case s1 = "1"
    case s3 = "3"
    case s5 = "5"
    case s10 = "10"
    case s15 = "15"
    case s30 = "30"
    case s60 = "60"
    case infinite = "∞"

    var id: String { rawValue }
    var title: String { self == .infinite ? "∞" : "\(rawValue)s" }
    var seconds: Double? { self == .infinite ? nil : Double(rawValue) }
}

extension SlowShutterSequenceSpec {
    /// Apply the user-selected wall-clock capture duration while preserving the
    /// preset's blend mode, per-frame exposure and minimum frame count.
    func applying(_ duration: SlowShutterDuration) -> Self {
        let rate = captureDuration.flatMap { $0 > 0 ? Double(frameCount) / $0 : nil } ?? 10
        if let seconds = duration.seconds {
            let frames = max(minimumFrames, min(36_000, Int(ceil(seconds * rate))))
            return SlowShutterSequenceSpec(frameCount: frames,
                                           totalDuration: frameExposureSeconds * Double(frames),
                                           blend: blend, exposureOverride: exposureOverride,
                                           captureDuration: seconds, minimumFrames: minimumFrames)
        }
        // ∞ 只由用户结束/取消；逐帧融合仅保留固定数量源图，不用有限帧数冒充无限。
        let frames = Int.max
        return SlowShutterSequenceSpec(frameCount: frames,
                                       totalDuration: frameExposureSeconds * Double(frames),
                                       blend: blend, exposureOverride: exposureOverride,
                                       captureDuration: nil, minimumFrames: minimumFrames)
    }
}

extension SlowShutterPreset {
    /// Total capture duration choices that make sense for the preset. The
    /// duration popup filters its 10 options through this range.
    var captureDurationRange: ClosedRange<Double>? {
        switch self {
        case .lightTrails: return 10...30
        case .silkyWater: return 5...15
        case .motionBlur: return 1...3
        case .panning: return 0.5...2
        case .starTrails: return 60...(.infinity)
        }
    }

    func allows(_ duration: SlowShutterDuration) -> Bool {
        guard let range = captureDurationRange else { return true }
        guard let seconds = duration.seconds else { return self == .starTrails }
        return range.contains(seconds)
    }

    var defaultCaptureDuration: SlowShutterDuration {
        switch self {
        case .lightTrails: return .s15
        case .silkyWater: return .s10
        case .motionBlur: return .s3
        case .panning: return .s1
        case .starTrails: return .s60
        }
    }
}

enum SlowShutterPresetLayout {
    static func buttonWidth(availableWidth: Double, count: Int = SlowShutterPreset.allCases.count) -> Double {
        guard availableWidth.isFinite, count > 0 else { return 40 }
        let spacing = Double(max(0, count - 1)) * 2
        // 与五镜头按钮共用 42pt 上限，宽屏下格宽一致，窄屏继续按可用宽度收缩。
        return min(42, max(16, (availableWidth - 4 - spacing) / Double(count)))
    }
}

enum SlowShutterPreviewPolicy {
    /// Keep the live viewfinder responsive only once exposure reaches 1/15 s.
    /// This trigger is intentionally separate from the 1/30 s preview cap.
    static let optimizationTriggerDuration = 1.0 / 15.0
    static let previewMaximumDuration = 1.0 / 30.0

    static func shouldAutomaticallyAssist(currentExposureSeconds: Double, presetMaximumSeconds: Double?) -> Bool {
        let threshold = optimizationTriggerDuration - 0.0005
        guard currentExposureSeconds.isFinite, currentExposureSeconds >= threshold,
              let presetMaximumSeconds, presetMaximumSeconds.isFinite,
              presetMaximumSeconds >= threshold else { return false }
        return true
    }

    static func manualExposureNeedsAssist(slowShutterEnabled: Bool, requestedExposureSeconds: Double) -> Bool {
        slowShutterEnabled && requestedExposureSeconds.isFinite
            && requestedExposureSeconds >= optimizationTriggerDuration - 0.0005
    }
}

enum SlowShutterBlendMode: String, Equatable {
    case lighten
    case handheldAlignedLighten
    case average
    case handheldAlignedAverage
    case handheldAlignedMotionBlur
    case subjectAlignedAverage
    case subjectAlignedPanning
}

struct SlowShutterSequenceSpec: Equatable {
    let frameCount: Int
    let totalDuration: Double
    let blend: SlowShutterBlendMode
    var exposureOverride: Double? = nil
    var captureDuration: Double? = nil
    var minimumFrames: Int = 1

    /// 累计曝光量不等于墙钟拍摄时间，原生出片和逐帧合并也需要时间。
    var frameExposureSeconds: Double { exposureOverride ?? totalDuration / Double(frameCount) }
}

extension SlowShutterPreset {
    /// 静态声明时间采样入口；开始时再用真实测光或用户手动曝光替换单帧参数。
    var sequenceSpec: SlowShutterSequenceSpec? {
        switch self {
        case .lightTrails: return .init(frameCount:96,totalDuration:10,blend:.handheldAlignedLighten,captureDuration:10,minimumFrames:8)
        case .silkyWater: return .init(frameCount:64,totalDuration:8,blend:.handheldAlignedAverage,captureDuration:8,minimumFrames:8)
        case .motionBlur: return .init(frameCount:24,totalDuration:2,blend:.handheldAlignedMotionBlur,captureDuration:2,minimumFrames:6)
        case .starTrails: return .init(frameCount:512,totalDuration:120,blend:.lighten,captureDuration:120,minimumFrames:16)
        case .panning: return .init(frameCount:8,totalDuration:1,blend:.subjectAlignedPanning,captureDuration:1,minimumFrames:3)
        }
    }

    /// 流水和长序列逐帧渲染，避免采样帧数增加后保留所有全分辨率源图。
    var usesStreamingComposition: Bool { true }
    var isMultiFrame: Bool { sequenceSpec != nil }
}

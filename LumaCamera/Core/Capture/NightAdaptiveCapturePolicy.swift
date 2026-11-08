import Foundation

/// 自适应张数是应用策略，不是 Apple 公布的 Night mode 阈值。
/// 单次仍使用设备支持的三张包围，后续批次在场景稳定时追加中间曝光降噪帧。
enum NightAdaptiveCapturePolicy {
    struct Exposure: Equatable { let seconds: Double; let iso: Double }

    /// A挡暗光静态请求使用更长曝光收集光线，不把预览的短快门/高ISO直接当夜景基准。
    /// 这是应用策略：暗度足够时最多增加2EV；自动夜景单帧另受手持上限约束，M挡不经过此规划器。
    static func automaticExposure(iso: Double, seconds: Double, durationRange: ClosedRange<Double>,
                                  isoRange: ClosedRange<Double>) -> Exposure? {
        guard iso.isFinite, seconds.isFinite, iso > 0, seconds > 0,
              durationRange.lowerBound > 0, durationRange.upperBound.isFinite,
              isoRange.lowerBound > 0, isoRange.upperBound.isFinite else { return nil }
        let demand = iso * seconds
        guard demand.isFinite, demand >= 64 else { return nil }
        let gain = min(4, max(1, demand / 64))
        let product = demand * gain
        let maximum = min(durationRange.upperBound, max(durationRange.lowerBound, handheldMaximumExposureSeconds))
        // 同样曝光量优先分配给快门，降低 ISO 带来的高ISO噪点；暗景最多用到手持上限。
        // 极端暗景仍由 maximum/gain 限制，不会无限延长。
        let duration = min(maximum, max(durationRange.lowerBound, max(seconds, product / 640)))
        let sensitivity = min(isoRange.upperBound, max(isoRange.lowerBound, product / duration))
        return Exposure(seconds: duration, iso: sensitivity)
    }

    /// 高光保护帧和亮帧都与首批基准关联；追加批次不重新读取AE导致明暗漂移。
    static func bracket(_ base: Exposure, bias: Double, durationRange: ClosedRange<Double>,
                        isoRange: ClosedRange<Double>) -> Exposure {
        let product = base.seconds * base.iso * pow(2, bias)
        let duration = min(durationRange.upperBound, max(durationRange.lowerBound, base.seconds * pow(2, bias)))
        return Exposure(seconds: duration, iso: min(isoRange.upperBound, max(isoRange.lowerBound, product / duration)))
    }
    /// A 挡自动夜景单帧上限 2 秒；比 1 秒多收集一档光，减少后续数字提亮。
    /// 手持稳定性由多帧配准、运动保护和镜头防抖承担。M 挡仍可使用硬件更长曝光。
    static let handheldMaximumExposureSeconds = 2.0

    static let maximumFrameCount = 9
    static let maximumSequenceSeconds = 8.0
    static let maximumCompressedBytes = 80 * 1024 * 1024

    static func exposureIndex(iso: Double, seconds: Double, bias: Double) -> Double? {
        guard iso.isFinite, iso > 0, seconds.isFinite, seconds > 0, bias.isFinite else { return nil }
        let value = iso * seconds / pow(2, bias)
        return value.isFinite && value > 0 ? value : nil
    }

    static func targetFrameCount(exposureIndex: Double?, constrained: Bool, automaticExposure: Exposure? = nil) -> Int {
        guard !constrained else { return 3 }
        // EV修正后的环境读数不能覆盖真实长曝光/高ISO的降噪需求。
        let captureDemand = automaticExposure.map { $0.seconds * $0.iso } ?? 0
        let exposureIndex = max(exposureIndex.flatMap { $0.isFinite ? $0:nil } ?? 0,
                                captureDemand.isFinite ? captureDemand:0)
        if exposureIndex >= 256 { return 9 }
        if exposureIndex >= NightCaptureEnvironmentGate.triggerExposureIndex { return 6 }
        return 3
    }

    /// 低纹理等未知状态仍允许补足六帧；实际运动停止追加，融合器逐区域保护移动内容。
    static func shouldContinue(target: Int, submitted: Int, received: Int, motion: NightSceneMotion,
                               elapsed: Double, nextBatchSeconds: Double, compressedBytes: Int, constrained: Bool) -> Bool {
        !constrained && motion != .moving && (motion != .unknown || submitted < 6)
            && target > submitted && received == submitted
            && submitted >= 3 && submitted < maximumFrameCount
            && elapsed.isFinite && elapsed < maximumSequenceSeconds
            && nextBatchSeconds.isFinite && nextBatchSeconds >= 0
            && elapsed + nextBatchSeconds <= maximumSequenceSeconds
            && compressedBytes < maximumCompressedBytes
    }
}

enum NightSceneMotion: String { case stable = "稳定", moving = "运动或晃动", unknown = "无法可靠评估" }

/// 独立夜景只用本次快门之后、同一供图镜头的稳定预览曝光。
struct IndependentNightMetering {
    struct Sample {
        let time: TimeInterval
        let sourceID: String
        let exposure: NightAdaptiveCapturePolicy.Exposure
        let adjusting: Bool
    }

    static let timeout: TimeInterval = 2.5
    let startedAt: TimeInterval
    private var lastTime = -Double.infinity
    private var anchor: Sample?
    private var count = 0

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func observe(_ sample: Sample) -> NightAdaptiveCapturePolicy.Exposure? {
        guard sample.time.isFinite, sample.time >= startedAt, sample.time > lastTime else { return nil }
        lastTime = sample.time
        let exposure = sample.exposure
        guard !sample.adjusting, exposure.seconds.isFinite, exposure.seconds > 0, exposure.iso.isFinite, exposure.iso > 0 else {
            anchor = nil; count = 0
            return nil
        }
        guard let anchor, anchor.sourceID == sample.sourceID,
              abs(exposure.seconds - anchor.exposure.seconds) <= max(0.0005, anchor.exposure.seconds * 0.03),
              abs(exposure.iso - anchor.exposure.iso) <= max(8, anchor.exposure.iso * 0.03) else {
            anchor = sample; count = 1
            return nil
        }
        count += 1
        // 以窗口首帧为基准，逐帧小幅漂移也不能被当作稳定。
        guard count >= 3, sample.time - anchor.time >= 0.35 else { return nil }
        return exposure
    }
}

struct NightSceneAssessment {
    var motion: NightSceneMotion
    var maximumShift: Double = 0
    var changedFraction: Double = 0
    var reason = ""
}

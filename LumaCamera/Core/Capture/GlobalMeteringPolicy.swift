import Foundation
import CoreImage

/// 全画面平均测光：场景稳定后只计算一个绝对补偿，不能从已补偿的画面反复累加。
/// 目标灰度和门限属于应用策略，不代表苹果原生相机的私有测光算法。
struct GlobalMeteringPolicy {
    struct Sample {
        let mean: Double
        let shape: [Double]
        let exposureProduct: Double
        let deviceBias: Double
        let userBias: Double
        let time: Double
        let route: String

        var sceneLevel: Double { log2(max(mean, 0.000001) / max(exposureProduct, 0.000001)) }
        func structureDistance(to other: Sample) -> Double {
            guard shape.count == other.shape.count, !shape.isEmpty else { return 0 }
            return zip(shape, other.shape).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(shape.count)
        }
        func distance(to other: Sample) -> Double {
            max(abs(sceneLevel - other.sceneLevel) / 0.8, structureDistance(to: other) / 0.35)
        }
    }

    private var reference: Sample?
    private var candidate: Sample?
    private var candidateCount = 0
    private var waiting = false
    private var waitingSince = -Double.infinity
    private var resumeAfter = -Double.infinity
    private var rebaseAfterApplication = false
    private var blockedUntilSceneChange = false
    private(set) var applications = 0
    private(set) var computations = 0
    private(set) var lastComputedTarget: Double?

    mutating func reset() { self = Self() }

    /// 用户调整、曝光锁定或拍摄过渡期间，不沿用未完成的场景判断。
    mutating func suspend() { candidate = nil; candidateCount = 0 }

    mutating func complete(at time: Double) {
        waiting = false
        blockedUntilSceneChange = false
        resumeAfter = time + 0.45
        rebaseAfterApplication = true
    }

    mutating func consider(_ sample: Sample, adjusting: Bool) -> Double? {
        guard sample.mean.isFinite, sample.mean > 0.00001,
              sample.exposureProduct.isFinite, sample.exposureProduct > 0,
              sample.deviceBias.isFinite, sample.userBias.isFinite,
              sample.time.isFinite, sample.shape.allSatisfy(\.isFinite) else { suspend(); return nil }
        if let reference, reference.route != sample.route { reset() }
        if waiting, sample.time - waitingSince > 4 {
            // 会话中断可能没有完成回调；超时只重建观察基准，不重复下发曝光。
            complete(at: sample.time)
            blockedUntilSceneChange = true
        }
        guard !waiting, sample.time >= resumeAfter else { return nil }
        if rebaseAfterApplication {
            // ISP的色调映射不是严格线性的。补偿完成后重新建立观察基准，避免把自己的曝光响应当成新场景。
            rebaseAfterApplication = false
            // 冷却期间换了明确的构图，不能把新场景直接吞作旧补偿的基准。
            if reference == nil || reference!.structureDistance(to: sample) < 0.35 {
                reference = sample; suspend(); return nil
            }
        }
        if let reference {
            let sameScene = reference.distance(to: sample) < 1
            if !sameScene { blockedUntilSceneChange = false }
            let delta = Self.target(for: sample).map { abs($0 - (sample.deviceBias - sample.userBias)) } ?? 0
            // 实时模式允许稳定的新目标跟进；达到死区即停止。超时失败仍等真正换场景再重试。
            if sameScene && (delta < 0.1 || blockedUntilSceneChange) { suspend(); return nil }
        }
        if let candidate, candidate.route == sample.route,
           abs(candidate.userBias - sample.userBias) < 0.01,
           candidate.distance(to: sample) < 0.35,
           abs(log2(sample.mean / candidate.mean)) < 0.2 {
            candidateCount += 1
        } else {
            candidate = sample; candidateCount = 1; return nil
        }
        // 系统调整标志只延长观察，不再每次清空候选；画面/曝光数据不稳定仍会重启取样。
        let requiredCount = adjusting ? 4 : 3
        let requiredTime = adjusting ? 0.55 : 0.35
        guard let candidate, candidateCount >= requiredCount, sample.time - candidate.time >= requiredTime else { return nil }
        reference = sample; suspend()
        // 先还原到设备总补偿为0时的估计亮度，再从头计算场景目标；不使用上次globalBias累加。
        // 用户EV保留为独立偏好，由引擎在目标全局补偿之外叠加。
        // ISP不是严格线性曝光模型，此处是预览域估计，不宣称还原传感器照度。
        guard let target = Self.target(for: sample) else { return nil }
        computations += 1
        lastComputedTarget = target
        guard abs(target - (sample.deviceBias - sample.userBias)) >= 0.1 else { return nil }
        waiting = true; waitingSince = sample.time; applications += 1
        return target
    }

    /// 每个有效取样都可立即得到读数；设备是否应用由上面的场景/去抖状态独立决定。
    static func target(for sample: Sample) -> Double? {
        guard sample.mean.isFinite, sample.mean > 0.00001, sample.deviceBias.isFinite else { return nil }
        let value = log2(0.18 / sample.mean) + sample.deviceBias
        return min(max(value, -2), 2)
    }

    /// 平滑的是本轮重新算出的绝对目标，不是把亮度误差不断累加到EV。
    static func appliedCorrection(target: Double, current: Double) -> Double {
        let step = min(max((target - current) * 0.5, -0.5), 0.5)
        return current + step
    }

    /// 全手动时bias不控制曝光；用成片的ISO×快门/真实光圈²换算建议，兼容临时流畅预览。
    static func manualSample(_ sample: Sample, plannedExposureProduct: Double) -> Sample {
        let predictedMean = sample.mean * plannedExposureProduct / sample.exposureProduct
        return Sample(mean: predictedMean, shape: sample.shape, exposureProduct: plannedExposureProduct,
            deviceBias: 0, userBias: 0, time: sample.time,
            route: sample.route + "/manual/\(plannedExposureProduct)")
    }

    /// 在滤镜/影调之前读取低分辨率线性sRGB网格；全画幅均值另用面积平均，避免中心采样偏置。
    static func analyze(_ image: CIImage, context: CIContext) -> (mean: Double, shape: [Double]) {
        let mean = Imaging.meanLuminance(image, context: context)
        let size = 8
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size) / image.extent.width, y: CGFloat(size) / image.extent.height))
        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: size * 16,
                           bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        }
        let shape = stride(from: 0, to: pixels.count, by: 4).map { i in
            let value = Double(pixels[i]) * 0.2126 + Double(pixels[i+1]) * 0.7152 + Double(pixels[i+2]) * 0.0722
            return log2(max(value, 0.0001) / max(mean, 0.0001))
        }
        return (mean, shape)
    }
}

/// 界面分别显示用户设置、应用测光补偿与设备读回值，不用用户EV冒充总补偿。
struct GlobalMeteringReadout: Equatable {
    var user: Double = 0
    var correction: Double = 0
    var actual: Double = 0
    var automatic = false
    var suggestion: Double?
    var target: Double?
}

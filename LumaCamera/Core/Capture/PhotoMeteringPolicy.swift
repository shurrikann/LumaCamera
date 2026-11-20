import Foundation
import CoreImage

/// 中央重点和高光保护共享场景稳定、设备回读与补偿限速。
/// 目标灰度和门限属于应用策略，不代表苹果原生相机的私有测光算法。
struct PhotoMeteringPolicy {
    struct Sample {
        let mean: Double
        let shape: [Double]
        let exposureProduct: Double
        let deviceBias: Double
        let userBias: Double
        let time: Double
        let route: String
        var highlights = Highlights()
        /// 当前画幅中心加权平均亮度 / 全画面平均亮度；用于相对中心修正。
        var centerRatio: Double = 1
        /// 预览实际携带的EDR headroom；SDR为1。
        var highlightHeadroom: Double = 1

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

    mutating func consider(_ sample: Sample, adjusting: Bool, mode: CameraMetering = .centerWeighted) -> Double? {
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
        let highlightActive = mode == .highlight && sample.deviceBias - sample.userBias < -0.05
        if rebaseAfterApplication {
            // ISP的色调映射不是严格线性的。补偿完成后重新建立观察基准，避免把自己的曝光响应当成新场景。
            rebaseAfterApplication = false
            // 冷却期间换了明确的构图，不能把新场景直接吞作旧补偿的基准。
            if reference == nil || reference!.structureDistance(to: sample) < 0.35 {
                reference = sample; suspend(); return nil
            }
        }
        guard let target = Self.target(for: sample, mode: mode, highlightActive: highlightActive) else { return nil }
        if let reference {
            let sameScene = reference.distance(to: sample) < 1
            if !sameScene { blockedUntilSceneChange = false }
            let delta = abs(target - (sample.deviceBias - sample.userBias))
            // 实时模式允许稳定的新目标跟进；达到死区即停止。超时失败仍等真正换场景再重试。
            if sameScene && (delta < 0.1 || blockedUntilSceneChange) { suspend(); return nil }
        }
        if let candidate, candidate.route == sample.route,
           abs(candidate.userBias - sample.userBias) < 0.01,
           candidate.distance(to: sample) < 0.35,
           (mode != .centerWeighted || abs(Self.centerCorrection(candidate) - Self.centerCorrection(sample)) < 0.1),
           (mode != .highlight || abs(Self.highlightTarget(candidate, active: highlightActive)
                - target) < 0.15),
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
        // 先还原到设备总补偿为0时的估计亮度，再从头计算场景目标；不使用上次meteringBias累加。
        // 用户EV保留为独立偏好，由引擎在目标测光补偿之外叠加。
        // ISP不是严格线性曝光模型，此处是预览域估计，不宣称还原传感器照度。
        computations += 1
        lastComputedTarget = target
        guard abs(target - (sample.deviceBias - sample.userBias)) >= 0.1 else { return nil }
        waiting = true; waitingSince = sample.time; applications += 1
        return target
    }

    /// 每个有效取样都可立即得到读数；设备是否应用由上面的场景/去抖状态独立决定。
    static func target(for sample: Sample, mode: CameraMetering = .centerWeighted,
                       highlightActive: Bool = false) -> Double? {
        guard sample.mean.isFinite, sample.mean > 0.00001, sample.deviceBias.isFinite, sample.userBias.isFinite else { return nil }
        switch mode {
        case .centerWeighted: return centerCorrection(sample)
        case .highlight: return highlightTarget(sample, active: highlightActive)
        case .system, .spot: return nil
        }
    }

    /// 中央重点只做相对修正：中心比全画面暗时增加曝光，亮时减少曝光。
    /// 不追固定18%灰，也不改变用户EV；结果作为系统AE之外的附加补偿。
    private static func centerCorrection(_ sample: Sample) -> Double {
        guard sample.centerRatio.isFinite, sample.centerRatio > 0 else { return 0 }
        let correction = -0.5 * log2(sample.centerRatio)
        return min(max(correction, -1), 1)
    }

    private static let highlightEnterArea = 0.02
    private static let highlightExitArea = 0.015
    private static let highlightBlendStart = 0.04
    private static let highlightBlendEnd = 0.08
    private static let specularMaxPixels = 4

    private static func highlightTarget(_ sample: Sample, active: Bool) -> Double {
        // 先移除用户EV和已应用补偿，得到系统AE基准上的高光；用户EV最后再叠加。
        // 同一基础场景在用户EV变化时得到相同的基础保护量。
        let baselineGain = exp2(-sample.deviceBias)
        let headroom = sample.highlightHeadroom.isFinite ? max(sample.highlightHeadroom, 1) : 1
        let target = 0.90 * headroom
        let region = sample.highlights.brightRegion(above: target, gain: baselineGain)
        let area = region.area
        // 2%进入、1.5%退出；当前已有负补偿时保留到真正低于退出阈值。
        let isActive = area >= highlightEnterArea || (active && area >= highlightExitArea)
        guard isActive else { return 0 }
        // 平滑移动分位秩，并限制在有效亮区内。窄亮区的 P95 不能取到暗背景。
        let fraction = 0.99 - 0.04 * smoothstep(area, highlightBlendStart, highlightBlendEnd)
        guard let peak = region.percentile(fraction) else { return 0 }
        let protection = log2(target / peak) - 0.15
        return min(max(protection, -2), 0)
    }

    private static func smoothstep(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        let t = min(max((value - lower) / max(upper - lower, 0.0001), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 平滑的是本轮重新算出的绝对目标，不是把亮度误差不断累加到EV。
    static func appliedCorrection(target: Double, current: Double) -> Double {
        let step = min(max((target - current) * 0.5, -0.5), 0.5)
        return current + step
    }

    /// 全手动时bias不控制曝光；用成片的ISO×快门/真实光圈²换算建议，兼容临时流畅预览。
    static func manualSample(_ sample: Sample, plannedExposureProduct: Double) -> Sample {
        let gain = plannedExposureProduct / sample.exposureProduct
        return Sample(mean: sample.mean * gain, shape: sample.shape, exposureProduct: plannedExposureProduct,
            deviceBias: 0, userBias: 0, time: sample.time,
            route: sample.route + "/manual/\(plannedExposureProduct)",
            highlights: sample.highlights.scaled(by: gain), centerRatio: sample.centerRatio,
            highlightHeadroom: sample.highlightHeadroom)
    }

    struct Highlights {
        struct BrightRegion {
            let values: [Double]
            let sampleCount: Int

            var area: Double { Double(values.count) / Double(max(sampleCount, 1)) }

            func percentile(_ fraction: Double) -> Double? {
                guard !values.isEmpty else { return nil }
                let globalRank = Double(sampleCount - 1) * fraction
                let brightRank = globalRank - Double(sampleCount - values.count)
                let rank = min(max(brightRank, 0), Double(values.count - 1))
                let lower = Int(rank), upper = min(lower + 1, values.count - 1)
                return values[lower] + (values[upper] - values[lower]) * (rank - Double(lower))
            }
        }

        private let luminances: [Double]
        private let gridSize: Int?

        init(luminances: [Double] = [], gridSize: Int? = nil) {
            self.luminances = luminances
            self.gridSize = gridSize
        }

        func brightRegion(above threshold: Double, gain: Double) -> BrightRegion {
            guard gain.isFinite, gain > 0 else { return BrightRegion(values: [], sampleCount: luminances.count) }
            let normalized = luminances.map { $0 * gain }
            let filtered = gridSize.map { removingIsolatedSpeculars(normalized, size: $0, threshold: threshold) }
                ?? normalized
            return BrightRegion(values: filtered.filter { $0 > threshold }.sorted(), sampleCount: luminances.count)
        }

        func scaled(by gain: Double) -> Self {
            Self(luminances: luminances.map { $0 * gain }, gridSize: gridSize)
        }
    }

    /// 线性预览亮度。即使照片开启 HDR，拍照预览仍为 SDR，不能推断 RAW 高光余量。
    struct Analysis {
        let centerMean: Double
        let sceneMean: Double
        let shape: [Double]
        let highlights: Highlights
        let headroom: Double
    }

    static func analyze(_ image: CIImage, context: CIContext) -> Analysis {
        let size = 32
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return Analysis(centerMean: 0, sceneMean: 0, shape: [], highlights: Highlights(), headroom: 1) }
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: CGFloat(size) / extent.height,
                kCIInputAspectRatioKey: extent.height / extent.width
            ])
        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: size * 16,
                           bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        let lights = stride(from: 0, to: pixels.count, by: 4).map { i in
            let value = Double(pixels[i]) * 0.2126 + Double(pixels[i+1]) * 0.7152 + Double(pixels[i+2]) * 0.0722
            return max(value, 0)
        }
        guard lights.allSatisfy(\.isFinite) else { return Analysis(centerMean: 0, sceneMean: 0, shape: [], highlights: Highlights(), headroom: 1) }
        let reportedHeadroom = Double(image.contentHeadroom)
        let headroom = reportedHeadroom.isFinite ? max(reportedHeadroom, 1) : 1
        let shortEdge = min(extent.width, extent.height)
        let widthScale = Double(extent.width / shortEdge)
        let heightScale = Double(extent.height / shortEdge)
        var centerSum = 0.0
        var weightSum = 0.0
        var sceneSum = 0.0
        var blocks = [Double](repeating: 0, count: 64)
        for (index, light) in lights.enumerated() {
            let x = index % size
            let y = index / size
            let nx = (2 * (Double(x) + 0.5) / Double(size) - 1) * widthScale
            let ny = (2 * (Double(y) + 0.5) / Double(size) - 1) * heightScale
            let t = min(max((hypot(nx, ny) - 0.55) / 0.9, 0), 1)
            let weight = 1 - 0.8 * t * t * (3 - 2 * t)
            centerSum += light * weight
            weightSum += weight
            sceneSum += light
            blocks[(y / 4) * 8 + x / 4] += light
        }
        let sceneMean = sceneSum / Double(lights.count)
        let shape = blocks.map { log2(max($0 / 16, 0.0001) / max(sceneMean, 0.0001)) }
        return Analysis(centerMean: centerSum / max(weightSum, 0.0001), sceneMean: sceneMean,
                        shape: shape, highlights: Highlights(luminances: lights, gridSize: size), headroom: headroom)
    }

    /// 只剔除与大面积亮区断开的微小高亮连通块，避免孤立点光源污染p99。
    /// 这是空间启发式，不宣称识别真实镜面材质。
    static func removingIsolatedSpeculars(_ lights: [Double], size: Int, threshold: Double) -> [Double] {
        guard size > 0, lights.count == size * size, threshold.isFinite, threshold > 0 else { return lights }
        var visited = [Bool](repeating: false, count: lights.count)
        var filtered = lights
        for start in lights.indices where !visited[start] && lights[start] > threshold {
            var stack = [start]
            var component: [Int] = []
            visited[start] = true
            while let index = stack.popLast() {
                component.append(index)
                let x = index % size
                let y = index / size
                if x > 0 { let next = index - 1; if !visited[next], lights[next] > threshold { visited[next] = true; stack.append(next) } }
                if x + 1 < size { let next = index + 1; if !visited[next], lights[next] > threshold { visited[next] = true; stack.append(next) } }
                if y > 0 { let next = index - size; if !visited[next], lights[next] > threshold { visited[next] = true; stack.append(next) } }
                if y + 1 < size { let next = index + size; if !visited[next], lights[next] > threshold { visited[next] = true; stack.append(next) } }
            }
            if component.count <= specularMaxPixels {
                for index in component { filtered[index] = 0 }
            }
        }
        return filtered
    }
}

/// 界面分别显示用户设置、应用测光补偿与设备读回值，不用用户EV冒充总补偿。
struct PhotoMeteringReadout: Equatable {
    var user: Double = 0
    var correction: Double = 0
    var actual: Double = 0
    var automatic = false
    var suggestion: Double?
    var target: Double?
}

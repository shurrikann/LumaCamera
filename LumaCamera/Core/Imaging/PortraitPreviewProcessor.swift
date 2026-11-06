import AVFoundation
import CoreImage
import QuartzCore
import Vision

/// 在独立队列复用人物视频分割状态，只保留最新有效蒙版。
/// 人像模式开启期间持续提供取景虚化；成片仍优先使用拍摄时的原生蒙版。
final class PortraitPreviewProcessor {
    struct Metrics {
        let samples: Int
        let failures: Int
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
        let requestCreations: Int
        let acceptedMasks: Int
    }

    static let minimumInterval: TimeInterval = 0.10
    static let maximumMaskAge: TimeInterval = 0.55

    /// 原生照片蒙版没有交付时，仅对已拍摄静态图像运行一次高质量人物分割作为后备。
    /// 先缩到 2048 像素长边，避免高像素照片把 Vision 分割成本放大；输出蒙版会由渲染器映射回原图尺寸。
    static func segmentStillImage(_ image: CIImage) -> CIImage? {
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let longestSide = max(image.extent.width, image.extent.height)
        let scale = min(1, 2048 / longestSide)
        let segmentationImage = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let request = VNGeneratePersonSegmentationRequest()
        // 静态成片允许单次较慢处理，优先轮廓质量；实时预览仍由独立节流队列完成。
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: segmentationImage).perform([request])
            guard let observation = request.results?.first as? VNPixelBufferObservation,
                  containsPerson(observation.pixelBuffer) else { return nil }
            return CIImage(cvPixelBuffer: observation.pixelBuffer)
        } catch {
            return nil
        }
    }

    private let queue = DispatchQueue(label: "camera.portrait-segmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var inFlight = false
    private var lastRequestTime = -Double.infinity
    private var mask: CIImage?
    private var maskTime = -Double.infinity
    private var durations: [Double] = []
    private var failureCount = 0
    private var route = ""
    private var epoch: UInt64 = 0
    private var requestCreations = 0
    private var acceptedMasks = 0
    // 仅分割队列访问；同一段视频复用有状态请求，切镜/画幅/开关后重建。
    private var sequenceRequest: VNGeneratePersonSegmentationRequest?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var requestEpoch: UInt64?
    private var displayedStrength: Double?
    private var strengthTime = -Double.infinity

    func configure(enabled: Bool, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard self.enabled != enabled || self.generation != generation else { return }
        self.enabled = enabled
        self.generation = generation
        epoch &+= 1
        mask = nil
        maskTime = -Double.infinity
        lastRequestTime = -Double.infinity
        displayedStrength = nil
        strengthTime = -Double.infinity
        if !enabled {
            // 关闭后释放 Vision 的视频历史，避免人像未使用时仍保留输入帧资源。
            queue.async { [weak self] in
                self?.sequenceRequest = nil
                self?.sequenceHandler = VNSequenceRequestHandler()
                self?.requestEpoch = nil
            }
        }
    }

    func submit(_ pixelBuffer: CVPixelBuffer, time: TimeInterval, generation: UInt64, route: String = "") {
        lock.lock()
        if self.route != route {
            self.route = route
            epoch &+= 1
            mask = nil
            maskTime = -Double.infinity
        }
        guard enabled, self.generation == generation, !inFlight,
              time.isFinite, time - lastRequestTime >= Self.minimumInterval else {
            lock.unlock(); return
        }
        inFlight = true
        lastRequestTime = time
        let submittedEpoch = epoch
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            if self.requestEpoch != submittedEpoch || self.sequenceRequest == nil {
                let request = VNGeneratePersonSegmentationRequest()
                // Apple 建议逐帧视频使用 balanced；复用状态，而不是每帧从头建立人物轮廓。
                request.qualityLevel = .balanced
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                self.sequenceRequest = request
                self.sequenceHandler = VNSequenceRequestHandler()
                self.requestEpoch = submittedEpoch
                self.lock.lock(); self.requestCreations += 1; self.lock.unlock()
            }
            guard let request = self.sequenceRequest else { return }
            var result: CIImage?
            do {
                try self.sequenceHandler.perform([request], on: pixelBuffer)
                if let observation = request.results?.first as? VNPixelBufferObservation,
                   Self.containsPerson(observation.pixelBuffer) {
                    result = CIImage(cvPixelBuffer: observation.pixelBuffer)
                }
            } catch {
                result = nil
            }
            let elapsed = (CACurrentMediaTime() - start) * 1000

            self.lock.lock()
            self.inFlight = false
            self.lock.unlock()
            self.recordSegmentationResult(result, completedAt: CACurrentMediaTime(),
                                          generation: generation, durationMilliseconds: elapsed,
                                          sourceTime: time, epoch: submittedEpoch)
        }
    }

    private func recordSegmentationResult(_ result: CIImage?, completedAt: TimeInterval,
                                          generation: UInt64, durationMilliseconds: Double?,
                                          sourceTime: TimeInterval? = nil, epoch: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, self.generation == generation, epoch == nil || epoch == self.epoch else { return }
        if let result {
            mask = result
            maskTime = sourceTime ?? completedAt
            acceptedMasks += 1
        } else {
            failureCount += 1
            // 漏检时不瞬间切成清晰画面；由源帧真实年龄控制短暂保持与逐渐退场。
        }
        if let durationMilliseconds {
            durations.append(durationMilliseconds)
            if durations.count > 120 { durations.removeFirst(durations.count - 120) }
        }
    }

    #if DEBUG
    func recordSegmentationResultForTesting(_ result: CIImage?, completedAt: TimeInterval,
                                            generation: UInt64) {
        recordSegmentationResult(result, completedAt: completedAt, generation: generation,
                                 durationMilliseconds: nil)
    }
    #endif

    func latestMask(generation: UInt64, now: TimeInterval = CACurrentMediaTime()) -> CIImage? {
        latestSnapshot(generation: generation, now: now)?.mask
    }

    func latestSnapshot(generation: UInt64, now: TimeInterval = CACurrentMediaTime()) -> (mask: CIImage, visibility: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, self.generation == generation, let mask,
              now.isFinite, now - maskTime <= Self.maximumMaskAge else { return nil }
        let age = max(0, now - maskTime)
        let visibility = min(1, max(0, (Self.maximumMaskAge - age) / 0.20))
        return (mask, visibility)
    }

    /// 在帧队列平滑强度，滑块仍立即记录目标值；不会为每个触控事件重置分割。
    func smoothStrength(_ target: Double, generation: UInt64, now: TimeInterval = CACurrentMediaTime()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard enabled, self.generation == generation else { return 0 }
        let target = PortraitPhotoRenderer.normalizedStrength(target)
        let delta = max(0, min(0.1, now - strengthTime))
        let value = displayedStrength.map { $0 + (target - $0) * (1 - exp(-delta / 0.045)) } ?? target
        displayedStrength = value
        strengthTime = now
        return value
    }

    func metrics() -> Metrics {
        lock.lock(); defer { lock.unlock() }
        let sorted = durations.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
            return sorted[max(0, index)]
        }
        return Metrics(samples: sorted.count, failures: failureCount,
                       medianMilliseconds: percentile(0.50), p95Milliseconds: percentile(0.95),
                       maximumMilliseconds: sorted.last ?? 0,
                       requestCreations: requestCreations, acceptedMasks: acceptedMasks)
    }

    private static func containsPerson(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return true }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return false }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var foreground = 0, sampled = 0
        let stride = max(1, min(width, height) / 32)
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                if pixels[y * rowBytes + x] > 24 { foreground += 1 }
                sampled += 1
            }
        }
        let coverage = Double(foreground) / Double(max(1, sampled))
        return coverage >= 0.005 && coverage <= 0.995
    }
}

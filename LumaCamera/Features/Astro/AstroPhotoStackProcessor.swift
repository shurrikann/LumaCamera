import CoreImage
import CoreVideo

/// Processes already decoded, linear frames on the caller's serial capture path.
struct AstroPhotoStackProcessor {
    private let context: CIContext
    private let linearSpace: CGColorSpace
    private var accumulator: CIImage?
    private var accumulatorBuffer: CVPixelBuffer?
    private var sceneRegistration: AstroSceneRegistration?
    private var qualityGate = AstroFrameQualityGate()
    private var groupAccumulators: [CIImage?] = [nil, nil, nil]
    private var groupBuffers: [CVPixelBuffer?] = [nil, nil, nil]
    private(set) var groupCounts = [0, 0, 0]
    private(set) var acceptedFrames = 0
    private(set) var extent = CGRect.zero

    init(context: CIContext, linearSpace: CGColorSpace) {
        self.context = context
        self.linearSpace = linearSpace
    }

    mutating func reset() {
        releaseFrames()
        acceptedFrames = 0
        extent = .zero
        qualityGate = AstroFrameQualityGate()
    }

    mutating func releaseFrames() {
        accumulator = nil
        accumulatorBuffer = nil
        sceneRegistration = nil
        groupAccumulators = [nil, nil, nil]
        groupBuffers = [nil, nil, nil]
        groupCounts = [0, 0, 0]
    }

    func stackedImage() -> CIImage? {
        AstroTemporalMedian.combine(groupAccumulators.compactMap { $0 }, extent: extent)
    }

    func finishedImage(iso: Double) -> CIImage? {
        guard let stacked = stackedImage() else { return nil }
        let matte = sceneRegistration?.matte.image
        let flattened = AstroPostProcessor.flattenBackground(stacked, sky: matte)
        return AstroSignalProtection.denoise(flattened, iso: iso, context: context, sky: matte)
    }

    mutating func append(_ source: CIImage) -> Bool {
        let sourceExtent = source.extent.integral
        if extent == .zero { extent = CGRect(origin: .zero, size: sourceExtent.size) }
        var frame = source.cropped(to: sourceExtent)
            .transformed(by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY))
            .cropped(to: extent)
        let statistics = AstroFrameStatistics.measure(frame,context:context)
        switch qualityGate.consider(statistics) {
        case .reject: return true
        case .replaceReference:
            releaseFrames()
            acceptedFrames = 0
        case .accept: break
        }
        if sceneRegistration == nil {
            sceneRegistration = AstroSceneRegistration(reference: frame, context: context)
        } else {
            frame = sceneRegistration?.align(frame) ?? frame
            if sceneRegistration?.lastStarAlignmentSucceeded == false { return true }
        }
        if let reference = accumulator, let matte = sceneRegistration?.matte.image {
            frame = AstroTransientTracks.clean(frame,previous:reference,sky:matte,context:context)
            frame = AstroSignalProtection.temporalClean(frame, reference:reference, noise:statistics.noise, sky:matte)
        }

        let group = acceptedFrames % 3
        let count = groupCounts[group] + 1
        let combined: CIImage
        if let previous = groupAccumulators[group] {
            let alpha = 1.0 / Double(count)
            let current = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let old = previous.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            combined = current.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: old])
        } else {
            combined = frame
        }
        guard let next = materialize(combined) else { return false }
        groupAccumulators[group] = next.image
        groupBuffers[group] = next.buffer
        groupCounts[group] = count
        acceptedFrames += 1
        accumulator = next.image
        accumulatorBuffer = next.buffer
        return true
    }

    private func materialize(_ image: CIImage) -> (image: CIImage, buffer: CVPixelBuffer)? {
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: linearSpace)
        return (CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearSpace]), buffer)
    }
}

/// One queue owns all mutable stack state. A capture ID isolates cancelled or
/// superseded requests; no filter instance or accumulator is mutated on the UI thread.
final class AstroPhotoStackWorker: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let image: CIImage?
        let rendered: CGImage?
        let acceptedFrames: Int
    }
    private let queue = DispatchQueue(label: "camera.astro.photo.processing", qos: .userInitiated)
    private let context: CIContext
    private var stack: AstroPhotoStackProcessor
    private var captureID: UUID?

    init() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .priorityRequestLow: true])
        self.context = context
        stack = AstroPhotoStackProcessor(context: context, linearSpace: space)
    }
    func begin(_ id: UUID) {
        queue.async { self.stack.reset(); self.captureID = id }
    }
    func cancel(_ id: UUID) {
        queue.async {
            guard self.captureID == id else { return }
            self.stack.reset(); self.captureID = nil
        }
    }
    func append(_ data: Data, id: UUID, completion: @escaping @Sendable (Snapshot?) -> Void) {
        queue.async {
            autoreleasepool {
                guard self.captureID == id, let image = CIImage(data: data), self.stack.append(image) else {
                    completion(nil); return
                }
                completion(Snapshot(image: self.stack.stackedImage(), rendered: nil, acceptedFrames: self.stack.acceptedFrames))
            }
        }
    }
    func finish(id: UUID, iso: Double, completion: @escaping @Sendable (Snapshot?) -> Void) {
        queue.async {
            autoreleasepool {
                guard self.captureID == id, let image = self.stack.finishedImage(iso: iso),
                      let rendered = self.context.createCGImage(image, from: self.stack.extent) else {
                    completion(nil); return
                }
                let result = Snapshot(image: image, rendered: rendered, acceptedFrames: self.stack.acceptedFrames)
                self.stack.releaseFrames(); self.captureID = nil
                completion(result)
            }
        }
    }
}

struct AstroPhotoFrameBudget {
    let target: Int
    let maximumAttempts: Int
    init(target: Int) {
        self.target = max(1, target)
        maximumAttempts = self.target + max(3, self.target / 2)
    }
    func shouldContinue(accepted: Int, attempted: Int) -> Bool {
        accepted < target && attempted < maximumAttempts
    }
}

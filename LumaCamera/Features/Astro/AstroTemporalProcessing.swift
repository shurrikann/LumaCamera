import CoreImage
import CoreVideo
import Foundation

/// Slowly follows real lighting changes while damping frame-to-frame exposure/WB steps.
struct AstroTemporalTone {
    private var target: SIMD3<Double>?
    private var lastEV = 0.0
    mutating func process(_ image: CIImage, context: CIContext) -> CIImage {
        let scale = min(1,96/max(image.extent.width,image.extent.height))
        let small = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let w = max(1,Int(small.extent.width)), h = max(1,Int(small.extent.height))
        var pixels = [Float](repeating:0,count:w*h*4)
        context.render(small,toBitmap:&pixels,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,
            colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        let channels = (0..<3).map { channel in (0..<w*h).map { Double(pixels[$0*4+channel]) }.sorted()[w*h/2] }
        let current = SIMD3(channels[0],channels[1],channels[2])
        guard current.min() > 0.00001 else { return image }
        guard let old = target else { target = current; return image }
        let next = old*0.98+current*0.02
        target = next
        let desired = min(0.75,max(-0.75,log2(next.y/current.y)))
        let ev = min(lastEV+0.35,max(lastEV-0.35,desired)); lastEV = ev
        let gain = pow(2,ev)
        let red = min(1.05,max(0.95,(next.x/next.y)/(current.x/current.y)))
        let blue = min(1.05,max(0.95,(next.z/next.y)/(current.z/current.y)))
        return image.applyingFilter("CIColorMatrix",parameters:[
            "inputRVector":CIVector(x:gain*red,y:0,z:0,w:0),
            "inputGVector":CIVector(x:0,y:gain,z:0,w:0),
            "inputBVector":CIVector(x:0,y:0,z:gain*blue,w:0)])
    }
}

/// Positive elongated residuals in the sky, not a semantic aircraft classifier.
enum AstroTransientTracks {
    static func clean(_ image: CIImage, previous: CIImage?, sky: CIImage, context: CIContext) -> CIImage {
        guard let previous else { return image }
        let extent = image.extent, scale = min(1,256/max(extent.width,extent.height))
        let residual = AstroSignalProtection.difference(image,previous)
            .applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:sky])
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let w = max(1,Int(residual.extent.width)), h = max(1,Int(residual.extent.height))
        var pixels = [Float](repeating:0,count:w*h*4)
        context.render(residual,toBitmap:&pixels,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,
            colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        let values = (0..<w*h).map { max(0,pixels[$0*4]*0.2126+pixels[$0*4+1]*0.7152+pixels[$0*4+2]*0.0722) }
        let ordered = values.sorted(), threshold = max(0.015,ordered[ordered.count*9/10]*4)
        var visited = [Bool](repeating:false,count:w*h), mask = [UInt8](repeating:0,count:w*h)
        var marked = false
        for seed in values.indices where !visited[seed] && values[seed] > threshold {
            var points = [seed], cursor = 0; visited[seed] = true
            while cursor < points.count {
                let i = points[cursor]; cursor += 1
                let x = i%w, y = i/w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x+dx, ny = y+dy
                    if nx >= 0, nx < w, ny >= 0, ny < h {
                        let n = ny*w+nx
                        if !visited[n], values[n] > threshold { visited[n] = true; points.append(n) }
                    }
                } }
            }
            guard points.count >= 8 else { continue }
            let count = Double(points.count)
            let cx = points.reduce(0.0) { $0+Double($1%w) }/count, cy = points.reduce(0.0) { $0+Double($1/w) }/count
            var xx = 0.0, yy = 0.0, xy = 0.0
            for i in points { let x = Double(i%w)-cx, y = Double(i/w)-cy; xx += x*x; yy += y*y; xy += x*y }
            let discriminant = sqrt((xx-yy)*(xx-yy)+4*xy*xy)
            let major = (xx+yy+discriminant)/2/count, minor = (xx+yy-discriminant)/2/count
            guard major > 12, major/max(0.15,minor) > 15 else { continue }
            for i in points { mask[i] = 255 }; marked = true
        }
        guard marked, let provider = CGDataProvider(data:Data(mask) as CFData),
              let cg = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
                decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return image }
        let full = CIImage(cgImage:cg).transformed(by:CGAffineTransform(scaleX:1/scale,y:1/scale))
            .applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:1/scale])
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:0.5/scale]).cropped(to:extent)
        return previous.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:full]).cropped(to:extent)
    }
}

struct AstroTrailMotion {
    private var previous: [CGPoint] = []
    private var previousTime: Double?
    private(set) var velocity = CGPoint.zero
    private(set) var maximumGap = 1.0
    mutating func observe(_ image: CIImage, sky: CIImage, time: Double, context: CIContext) {
        let skyOnly = image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.black).cropped(to:image.extent),kCIInputMaskImageKey:sky])
        let points = AstroStarRegistration.stars(skyOnly,context:context)
        defer { previous = points; previousTime = time }
        guard let previousTime, time > previousTime, previous.count >= 4, points.count >= 4 else { return }
        let dt = time-previousTime
        var offsets = [CGPoint](), used = Set<Int>()
        for point in previous {
            let candidates = points.indices.filter { !used.contains($0) }
            guard let index = candidates.min(by:{ hypot(points[$0].x-point.x,points[$0].y-point.y) < hypot(points[$1].x-point.x,points[$1].y-point.y) }),
                  hypot(points[index].x-point.x,points[index].y-point.y) < 12 else { continue }
            used.insert(index); offsets.append(CGPoint(x:(points[index].x-point.x)/dt,y:(points[index].y-point.y)/dt))
        }
        guard offsets.count >= 4 else { return }
        let xs = offsets.map(\.x).sorted(), ys = offsets.map(\.y).sorted()
        let candidate = CGPoint(x:xs[xs.count/2],y:ys[ys.count/2])
        guard hypot(candidate.x,candidate.y) < 4 else { return }
        velocity = CGPoint(x:velocity.x*0.7+candidate.x*0.3,y:velocity.y*0.7+candidate.y*0.3)
        maximumGap = max(maximumGap,min(8,dt))
    }
    func fill(_ image: CIImage, sky: CIImage) -> CIImage {
        let speed = hypot(velocity.x,velocity.y), length = min(8,speed*maximumGap)
        guard speed > 0.05, length > 1.5 else { return image }
        let radius = min(4,Int(ceil(length/2))), dx = velocity.x/speed, dy = velocity.y/speed
        func shifted(_ source: CIImage, _ i: Int) -> CIImage {
            source.clampedToExtent().transformed(by:CGAffineTransform(translationX:CGFloat(i)*dx,y:CGFloat(i)*dy)).cropped(to:image.extent)
        }
        var dilated = image
        for i in -radius...radius { dilated = dilated.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:shifted(image,i)]) }
        var closed = dilated
        for i in -radius...radius { closed = closed.applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:shifted(dilated,i)]) }
        return closed.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:sky]).cropped(to:image.extent)
    }
}

// Capture IDs and a serial queue own mutable image state, independently of UI state.
struct AstroFrameProcessingResult: @unchecked Sendable {
    var image: CIImage? = nil
    var rendered: CGImage? = nil
    var buffer: CVPixelBuffer? = nil
    var count = 0
    var error: String? = nil
}
/// Retains the pool for one queued render; allocation occurs only on that queue.
struct AstroPixelBufferPoolReference: @unchecked Sendable {
    let pool: CVPixelBufferPool
}
final class AstroSerialImageWorker<Processor: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera.astro.temporal.processing", qos: .userInitiated)
    private var processor: Processor?
    private var captureID: UUID?
    func begin(_ id: UUID, make: @escaping @Sendable () -> Processor) {
        queue.async { self.processor = make(); self.captureID = id }
    }
    func cancel(_ id: UUID) {
        queue.async { guard self.captureID == id else { return }; self.processor = nil; self.captureID = nil }
    }
    func perform(id: UUID, operation: @escaping @Sendable (inout Processor) -> AstroFrameProcessingResult,
                 completion: @escaping @Sendable (AstroFrameProcessingResult?) -> Void) {
        queue.async {
            autoreleasepool {
                guard self.captureID == id, self.processor != nil else { completion(nil); return }
                completion(operation(&self.processor!))
            }
        }
    }
}
struct AstroTrailFrameProcessor: @unchecked Sendable {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
    /// Intermediate accumulation must stay linear. Using the display/output
    /// context here would gamma-encode every accumulated frame.
    private let accumulatorContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    ])
    var blend: AstroTrailBlend = .lighten
    init(blend: AstroTrailBlend = .lighten) { self.blend = blend }
    private(set) var capturedCount = 0
    private(set) var accumulator: CIImage?
    private var accumulatorBuffer: CVPixelBuffer?
    private var fusionExtent = CGRect.zero
    private var sceneRegistration: AstroSceneRegistration?
    private var qualityGate = AstroFrameQualityGate()
    private var trailMotion = AstroTrailMotion()
    private var previousTrail: CIImage?
    mutating func append(_ frame: CIImage, at now: CFTimeInterval) -> Bool {
        let extent = frame.extent.integral
        guard extent.width > 0, extent.height > 0 else { return true }
        if fusionExtent == .zero { fusionExtent = CGRect(origin: .zero, size: extent.size) }
        let raw = frame
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: fusionExtent)
        let statistics = AstroFrameStatistics.measure(raw,context:accumulatorContext)
        if qualityGate.consider(statistics) == .reject { return true }
        if sceneRegistration == nil { sceneRegistration = AstroSceneRegistration(reference: raw, context: accumulatorContext) }
        // Register the static ground only; stellar motion is the desired trail.
        var normalized = sceneRegistration?.stabilizeGround(raw) ?? raw
        if let sky = sceneRegistration?.matte.image {
            normalized = AstroTransientTracks.clean(normalized,previous:previousTrail,sky:sky,context:accumulatorContext)
            trailMotion.observe(normalized,sky:sky,time:now,context:accumulatorContext)
            previousTrail = AstroSceneRegistration(reference:normalized,context:accumulatorContext,matte:sceneRegistration?.matte).reference
        }
        let count = capturedCount + 1
        let combined: CIImage
        if let accumulator {
            switch blend {
            case .lighten:
                let sky = normalized.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: accumulator])
                if let matte = sceneRegistration?.matte, matte.confidence > 0.01 {
                    let a = 1.0/Double(count)
                    let current = normalized.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:a,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:a,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:a,w:0)])
                    let old = accumulator.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:1-a,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:1-a,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:1-a,w:0)])
                    let average = current.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:old])
                    combined = sky.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:average,kCIInputMaskImageKey:matte.image])
                } else { combined = sky }
            case .sum:
                combined = normalized.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: accumulator
                ])
            case .average:
                let alpha = 1.0 / Double(count)
                let current = normalized.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                let previous = accumulator.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 - alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 - alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 - alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                combined = current.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: previous
                ])
            }
        } else {
            combined = normalized
        }
        guard let next = materialize(combined) else { return false }
        accumulator = next.image
        accumulatorBuffer = next.buffer
        capturedCount = count
        return true
    }

    private func materialize(_ image: CIImage) -> (image: CIImage, buffer: CVPixelBuffer)? {
        let width = Int(fusionExtent.width.rounded())
        let height = Int(fusionExtent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_64RGBAHalf,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        accumulatorContext.render(image, to: buffer,
                                 bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                 colorSpace: linearSpace)
        // The half-float buffer contains linear-light values. Attach the same
        // color space explicitly; CIImage(cvPixelBuffer:) otherwise has no
        // reliable linear tag and the next blend treats it as sRGB.
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linearSpace])
        return (image, buffer)
    }

    mutating func finish(iso: Double) -> AstroFrameProcessingResult {
        guard let accumulator else { return .init(error: "没有可合成帧") }
        var image = AstroPostProcessor.flattenBackground(accumulator, sky: sceneRegistration?.matte.image)
        image = AstroSignalProtection.denoise(image, iso: iso, context: context, sky: sceneRegistration?.matte.image)
        if let sky = sceneRegistration?.matte.image { image = trailMotion.fill(image, sky: sky) }
        image = AstroPostProcessor.enhanceTrails(image)
        let rendered = context.createCGImage(image, from: fusionExtent)
        let result = AstroFrameProcessingResult(image: image, rendered: rendered, count: capturedCount,
            error: rendered == nil ? "合成失败" : nil)
        self.accumulator = nil; accumulatorBuffer = nil; previousTrail = nil; sceneRegistration = nil
        return result
    }
}

struct AstroTimelapseFrameProcessor: @unchecked Sendable {
    private let renderContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh, .priorityRequestLow: true])
    private var movieScene: AstroSceneRegistration?
    private var groupScene: AstroSceneRegistration?
    private var groupQuality = AstroFrameQualityGate()
    private var tone = AstroTemporalTone()
    private var currentWindow = -1
    private var fusionExtent = CGRect.zero
    private(set) var fusionCount = 0
    private(set) var fusionAccumulator: CIImage?
    mutating func process(_ image: CIImage, window: Int) -> AstroFrameProcessingResult {
        if window != currentWindow {
            currentWindow = window; groupScene = nil; groupQuality = AstroFrameQualityGate()
            fusionCount = 0; fusionAccumulator = nil
        }
        let extent = image.extent
        let scale = max(2160 / extent.width, 3840 / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = max(0, (scaled.extent.width - 2160) / 2), y = max(0, (scaled.extent.height - 3840) / 2)
        let crop = CGRect(x: scaled.extent.minX+x, y: scaled.extent.minY+y, width:2160, height:3840)
        let frame = scaled.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let fused = append(frame) ?? fusionAccumulator
        return AstroFrameProcessingResult(image: fused, count: fusionCount)
    }
    mutating func render(_ image: CIImage, watermark: Bool, pool: CVPixelBufferPool) -> AstroFrameProcessingResult {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else {
            return .init(error: "无法分配延时输出缓冲")
        }
        let stable = tone.process(image, context: renderContext)
        let output = watermark ? AstroWatermarkRenderer.overlay(on: stable) : stable
        renderContext.render(output, to: buffer, bounds: CGRect(x:0,y:0,width:2160,height:3840),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return .init(buffer: buffer)
    }
    mutating func append(_ source: CIImage) -> CIImage? {
        if movieScene == nil { movieScene = AstroSceneRegistration(reference: source, context: renderContext) }
        let stable = movieScene?.stabilizeGround(source) ?? source
        if groupScene == nil { groupScene = AstroSceneRegistration(reference: stable, context: renderContext, matte: movieScene?.matte) }
        let statistics = AstroFrameStatistics.measure(stable,context:renderContext)
        switch groupQuality.consider(statistics) {
        case .reject: return nil
        case .replaceReference:
            groupScene = AstroSceneRegistration(reference:stable,context:renderContext,matte:movieScene?.matte)
            fusionCount = 0; fusionAccumulator = nil
        case .accept: break
        }
        var frame = groupScene?.align(stable, ground: false) ?? stable
        guard groupScene?.lastStarAlignmentSucceeded != false else { return nil }
        if let reference = fusionAccumulator, let sky = movieScene?.matte.image {
            frame = AstroTransientTracks.clean(frame,previous:reference,sky:sky,context:renderContext)
            frame = AstroSignalProtection.temporalClean(frame,reference:reference,noise:statistics.noise,sky:sky)
        }
        if fusionExtent == .zero { fusionExtent = CGRect(x: 0, y: 0, width: 2160, height: 3840) }
        let count = fusionCount + 1
        let alpha = 1.0 / Double(count)
        let combined: CIImage
        if let fusionAccumulator {
            let current = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let previous = fusionAccumulator.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            combined = current.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: previous])
        } else {
            combined = frame
        }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 2160, 3840, kCVPixelFormatType_64RGBAHalf,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        renderContext.render(combined, to: buffer, bounds: fusionExtent,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        fusionCount = count
        fusionAccumulator = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        return fusionAccumulator
    }

}

import CoreImage

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

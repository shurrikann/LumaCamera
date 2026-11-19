import CoreImage
import Vision

/// A conservative, image-derived sky matte. This is not a semantic ML model.
struct AstroSkyMatte {
    let image: CIImage
    let groundROI: CGRect?
    let confidence: Double

    static func estimate(_ source: CIImage, context: CIContext) -> Self {
        let e = source.extent
        let scale = min(1, 128 / max(e.width, e.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
        guard w > 12, h > 12 else { return uniform(source, sky: false) }
        var rgba = [Float](repeating: 0, count: w*h*4)
        context.render(small, toBitmap: &rgba, rowBytes: w*16,
            bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let luma = (0..<w*h).map { i in max(0, rgba[i*4]*0.2126 + rgba[i*4+1]*0.7152 + rgba[i*4+2]*0.0722) }
        let points = AstroStarRegistration.stars(source, context: context)
        guard points.count >= 4 else {
            let gradients = (1..<w*h).map { abs(luma[$0]-luma[$0-1]) }.sorted()
            let structure = gradients[gradients.count*3/4]
            return uniform(source, sky: false, confidence: structure > 0.02 ? 1 : 0)
        }
        // Try every edge: RAW sensor orientation need not be portrait/upright.
        var best: (edge: Int, row: Int, length: Int, score: Float)?
        for edge in 0..<4 {
            let rows = edge < 2 ? h : w, columns = edge < 2 ? w : h
            func value(_ row: Int, _ column: Int) -> Float {
                switch edge {
                case 0: return luma[row*w+column]
                case 1: return luma[(h-1-row)*w+column]
                case 2: return luma[column*w+row]
                default: return luma[column*w+(w-1-row)]
                }
            }
            var texture = [Float](), level = [Float]()
            for row in 0..<rows {
                let samples = (1..<columns-1).map { value(row,$0) }.sorted()
                level.append(samples[samples.count/2])
                let changes = (1..<columns-1).map { abs(value(row,$0+1)-value(row,$0-1)) }.sorted()
                texture.append(changes[changes.count/2])
            }
            let base = texture.prefix(max(3,rows/5)).sorted()[max(3,rows/5)/2]
            let nominalBand = max(2, rows / 16)
            // Leave enough samples for evidence on the ground side, including
            // strips much narrower than a fifth of the image.
            for row in rows / 4..<(rows - 2) {
                let band = min(nominalBand, rows - row)
                let above = level[(row - band)..<row].reduce(0, +) / Float(band)
                let below = level[row..<(row + band)].reduce(0, +) / Float(band)
                let lowerTexture = texture[row..<(row + band)].reduce(0, +) / Float(band)
                let upperTexture = texture[0..<row].reduce(0,+)/Float(row)
                guard upperTexture <= max(0.01,base*2.5) else { continue }
                let contrast = abs(below-above)
                let score = max(0,lowerTexture-base*2) + contrast*0.5
                guard score > max(0.012,base*5) else { continue }
                // A sky proposal needs stars on its smooth side, not merely a dark wall.
                let fraction = CGFloat(row)/CGFloat(rows)
                let skyPoints = points.filter { p in
                    switch edge {
                    case 0: return (e.maxY-p.y)/e.height < fraction
                    case 1: return (p.y-e.minY)/e.height < fraction
                    case 2: return (p.x-e.minX)/e.width < fraction
                    default: return (e.maxX-p.x)/e.width < fraction
                    }
                }
                guard skyPoints.count >= 4 else { continue }
                if best == nil || score > best!.score { best = (edge,row,rows,score) }
            }
        }
        guard let best else { return uniform(source, sky: true) }
        let skyFraction = CGFloat(best.row) / CGFloat(best.length)
        let groundFraction = 1 - skyFraction
        let feather = min(0.025, groundFraction / 4)
        let groundInset = min(0.05, groundFraction / 3)
        let white: CGPoint, black: CGPoint, ground: CGRect
        switch best.edge {
        case 0:
            let y = e.maxY-e.height*skyFraction
            white = CGPoint(x:e.midX,y:y+e.height*feather); black = CGPoint(x:e.midX,y:y-e.height*feather)
            ground = CGRect(x:e.minX,y:e.minY,width:e.width,height:max(1,y-e.minY-e.height*groundInset))
        case 1:
            let y = e.minY+e.height*skyFraction
            white = CGPoint(x:e.midX,y:y-e.height*feather); black = CGPoint(x:e.midX,y:y+e.height*feather)
            ground = CGRect(x:e.minX,y:y+e.height*groundInset,width:e.width,height:max(1,e.maxY-y-e.height*groundInset))
        case 2:
            let x = e.minX+e.width*skyFraction
            white = CGPoint(x:x-e.width*feather,y:e.midY); black = CGPoint(x:x+e.width*feather,y:e.midY)
            ground = CGRect(x:x+e.width*groundInset,y:e.minY,width:max(1,e.maxX-x-e.width*groundInset),height:e.height)
        default:
            let x = e.maxX-e.width*skyFraction
            white = CGPoint(x:x+e.width*feather,y:e.midY); black = CGPoint(x:x-e.width*feather,y:e.midY)
            ground = CGRect(x:e.minX,y:e.minY,width:max(1,x-e.minX-e.width*groundInset),height:e.height)
        }
        let mask = CIFilter(name:"CILinearGradient", parameters:["inputPoint0":CIVector(cgPoint:black),
            "inputPoint1":CIVector(cgPoint:white), "inputColor0":CIColor.black,"inputColor1":CIColor.white])!.outputImage!.cropped(to:e)
        return Self(image:mask, groundROI:ground.intersection(e), confidence:Double(best.score))
    }
    static func uniform(_ source: CIImage, sky: Bool, confidence: Double = 0) -> Self {
        Self(image:CIImage(color:sky ? .white : .black).cropped(to:source.extent),
             groundROI:sky ? nil : source.extent, confidence:confidence)
    }
}

final class AstroSceneRegistration {
    let reference: CIImage
    let matte: AstroSkyMatte
    private let context: CIContext
    private(set) var registrationDiagnostic = "unattempted"
    init(reference: CIImage, context: CIContext, matte: AstroSkyMatte? = nil) {
        self.context = context
        self.matte = matte ?? .estimate(reference, context:context)
        let s = min(1,1024/max(reference.extent.width,reference.extent.height))
        let small = reference.transformed(by:CGAffineTransform(scaleX:s,y:s))
        if let cg = context.createCGImage(small, from:small.extent, format:.RGBAh,
            colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) {
            self.reference = CIImage(cgImage:cg).transformed(by:CGAffineTransform(scaleX:1/s,y:1/s)).cropped(to:reference.extent)
        } else { self.reference = reference }
    }
    func stabilizeGround(_ frame: CIImage) -> CIImage {
        guard matte.confidence > 0.01, let roi = matte.groundROI, roi.width > 16, roi.height > 16 else { return frame }
        let scale = min(1,512/max(roi.width,roi.height))
        func thumbnail(_ image: CIImage) -> CIImage {
            image.cropped(to:roi).transformed(by:CGAffineTransform(translationX:-roi.minX,y:-roi.minY))
                .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        }
        var displacement: CGPoint?
        let isNarrow = roi.width < reference.extent.width * 0.15 || roi.height < reference.extent.height * 0.15
        if !isNarrow {
            let a = thumbnail(reference), b = thumbnail(frame)
            let request = VNTranslationalImageRegistrationRequest(targetedCIImage:b, options:[:])
            do {
                try VNImageRequestHandler(ciImage:a, options:[:]).perform([request])
                if let result = request.results?.first {
                    let t = result.alignmentTransform
                    let dx = t.tx/scale, dy = t.ty/scale
                    if dx.isFinite, dy.isFinite, hypot(dx,dy) <= max(frame.extent.width,frame.extent.height)*0.05 {
                        displacement = CGPoint(x:dx,y:dy)
                    }
                }
            } catch { registrationDiagnostic = error.localizedDescription }
        }
        // A narrow strip can produce an apparently valid but ambiguous Vision
        // match. Require a local displacement to improve the unshifted result.
        if displacement == nil { displacement = boundedTranslation(frame:frame,roi:roi) }
        guard let displacement else { return frame }
        registrationDiagnostic = "dx=\(displacement.x) dy=\(displacement.y)"
        return frame.clampedToExtent().transformed(by:CGAffineTransform(translationX:displacement.x,y:displacement.y)).cropped(to:reference.extent)
    }
    /// Repeated windows/fences can produce an implausible global Vision match.
    /// A bounded subpixel search supplies the ordinary hand-shake alternative.
    private func boundedTranslation(frame: CIImage, roi: CGRect) -> CGPoint? {
        let scale = min(1,256/max(roi.width,roi.height))
        let w = Int(roi.width*scale), h = Int(roi.height*scale)
        guard w > 12, h > 12 else { return nil }
        func pixels(_ source: CIImage) -> [Double] {
            let image = source.cropped(to:roi).transformed(by:CGAffineTransform(translationX:-roi.minX,y:-roi.minY))
                .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            var rgba = [Float](repeating:0,count:w*h*4)
            context.render(image,toBitmap:&rgba,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            let values = (0..<w*h).map { Double(rgba[$0*4])*0.2126+Double(rgba[$0*4+1])*0.7152+Double(rgba[$0*4+2])*0.0722 }
            let mean = values.reduce(0,+)/Double(values.count)
            return values.map { $0-mean }
        }
        let a = pixels(reference), b = pixels(frame)
        guard a.reduce(0,{$0+$1*$1})/Double(a.count) > 0.000001 else { return nil }
        let radius = min(8,min(w,h)/4)
        func cost(_ dx: Double, _ dy: Double) -> Double {
            var sum = 0.0, count = 0
            for y in stride(from:radius+1,to:h-radius-2,by:3) {
                for x in stride(from:radius+1,to:w-radius-2,by:3) {
                    let sx = Double(x)-dx, sy = Double(y)+dy
                    let ix = Int(floor(sx)), iy = Int(floor(sy)), fx = sx-Double(ix), fy = sy-Double(iy)
                    let v = b[iy*w+ix]*(1-fx)*(1-fy)+b[iy*w+ix+1]*fx*(1-fy)+b[(iy+1)*w+ix]*(1-fx)*fy+b[(iy+1)*w+ix+1]*fx*fy
                    let d = a[y*w+x]-v; sum += d*d; count += 1
                }
            }
            return sum/Double(max(1,count)) + (dx*dx+dy*dy)*0.0000001
        }
        let unchanged = cost(0, 0)
        guard unchanged > 0.00002 else { return .zero }
        var best = CGPoint.zero, score = unchanged
        for y in -radius...radius { for x in -radius...radius {
            let c = cost(Double(x),Double(y))
            if c < score { score = c; best = CGPoint(x:x,y:y) }
        } }
        let coarse = best
        for y in -20...20 { for x in -20...20 {
            let dx = coarse.x+Double(x)*0.025, dy = coarse.y+Double(y)*0.025, c = cost(dx,dy)
            if c < score { score = c; best = CGPoint(x:dx,y:dy) }
        } }
        guard score <= unchanged * 0.95 else { return .zero }
        return CGPoint(x:best.x/scale,y:best.y/scale)
    }
    func align(_ frame: CIImage, ground: Bool = true) -> CIImage {
        let stable = ground ? stabilizeGround(frame) : frame
        let black = CIImage(color:.black).cropped(to:reference.extent)
        // Feathered ground edges are bright false stars. Match only the sky's
        // interior; retain the soft matte for the final compositing seam.
        let interior = matte.image.applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.99])
            .applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:max(3,reference.extent.width/256)]).cropped(to:reference.extent)
        let a = reference.applyingFilter("CIBlendWithMask", parameters:[kCIInputBackgroundImageKey:black,kCIInputMaskImageKey:interior])
        let b = stable.applyingFilter("CIBlendWithMask", parameters:[kCIInputBackgroundImageKey:black,kCIInputMaskImageKey:interior])
        guard let t = AstroStarRegistration.rigidTransform(reference:a, frame:b, context:context) else { registrationDiagnostic += " stars=unmatched"; return stable }
        registrationDiagnostic += " starTransform=\(t)"
        let sky = stable.clampedToExtent().transformed(by:t).cropped(to:reference.extent)
        return sky.applyingFilter("CIBlendWithMask", parameters:[kCIInputBackgroundImageKey:stable,kCIInputMaskImageKey:matte.image]).cropped(to:reference.extent)
    }
}

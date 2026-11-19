import CoreImage

struct AstroFrameStatistics {
    let median: Double, noise: Double, detail: Double
    static func measure(_ source: CIImage, context: CIContext) -> Self {
        let scale = min(1,192/max(source.extent.width,source.extent.height))
        let image = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let w = max(3,Int(image.extent.width)), h = max(3,Int(image.extent.height))
        var rgba = [Float](repeating:0,count:w*h*4)
        context.render(image,toBitmap:&rgba,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),
            format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        let luma = (0..<w*h).map { Double(max(0,rgba[$0*4]*0.2126+rgba[$0*4+1]*0.7152+rgba[$0*4+2]*0.0722)) }
        let ordered = luma.sorted(), middle = ordered[ordered.count/2]
        var residual = [Double](), laplacian = [Double]()
        for y in 1..<h-1 { for x in 1..<w-1 {
            let i = y*w+x, neighbors = [luma[i-1],luma[i+1],luma[i-w],luma[i+w]].sorted()
            residual.append(abs(luma[i]-(neighbors[1]+neighbors[2])*0.5))
            laplacian.append(abs(4*luma[i]-luma[i-1]-luma[i+1]-luma[i-w]-luma[i+w]))
        } }
        residual.sort(); laplacian.sort()
        let noise = residual[residual.count/2]/0.6745
        let signal = max(0,laplacian[laplacian.count*9/10]-noise*3)
        return Self(median:middle,noise:noise,detail:signal)
    }
}

struct AstroFrameQualityGate {
    enum Decision { case accept, replaceReference, reject }
    private(set) var examined = 0
    private var best = 0.0
    mutating func consider(_ statistics: AstroFrameStatistics) -> Decision {
        examined += 1
        let score = statistics.detail
        if examined <= 3, best > 0.002, score > best*1.8 { best = score; return .replaceReference }
        if best > 0.002, score < best*0.3 { return .reject }
        best = max(best,score)
        return .accept
    }
}

enum AstroSignalProtection {
    static func difference(_ image: CIImage, _ background: CIImage) -> CIImage {
        let negative = background.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:-1,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:-1,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:-1,w:0)])
        return image.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:negative]).cropped(to:image.extent)
    }
    static func luma(_ image: CIImage) -> CIImage {
        let v = CIVector(x:0.2126,y:0.7152,z:0.0722,w:0)
        return image.applyingFilter("CIColorMatrix",parameters:["inputRVector":v,"inputGVector":v,"inputBVector":v])
    }
    static func starMask(_ image: CIImage, noise: Double) -> CIImage {
        let background = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.5]).cropped(to:image.extent)
        return luma(difference(image,background))
            .applyingFilter("CIColorThreshold",parameters:["inputThreshold":max(0.002,noise*3)])
            .applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:1.8])
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:0.6]).cropped(to:image.extent)
    }
    /// Suppress unsupported positive sensor outliers after registration, while
    /// allowing bright stars already supported by the reference to vary.
    static func temporalClean(_ image: CIImage, reference: CIImage, noise: Double, sky: CIImage) -> CIImage {
        let limit = max(0.02,noise*8)
        let ceiling = reference.applyingFilter("CIColorMatrix",parameters:["inputBiasVector":CIVector(x:limit,y:limit,z:limit,w:0)])
        let clipped = image.applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:ceiling])
        let support = starMask(reference,noise:noise).applyingFilter("CIColorInvert")
        let mask = support.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:sky])
        return clipped.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask]).cropped(to:image.extent)
    }
    private static let denoiseKernel = MetalImageKernels.general("astroLinearDenoise")

    static func denoise(_ image: CIImage, iso: Double, context: CIContext, sky: CIImage? = nil) -> CIImage {
        let statistics = AstroFrameStatistics.measure(image, context: context)
        let noise = min(0.035, max(0.004, statistics.noise * 1.6 + 0.0008 * log2(max(100, iso) / 100)))
        let matte = sky ?? CIImage(color: .white).cropped(to: image.extent)
        return denoiseKernel?.apply(extent: image.extent, roiCallback: { index, region in
            index == 0 ? region.insetBy(dx: -1, dy: -1) : region
        }, arguments: [image.clampedToExtent(), matte, noise]) ?? image
    }
}

final class AstroFrameAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !busy else { return false }; busy = true; return true }
    func end() { lock.lock(); busy = false; lock.unlock() }
}

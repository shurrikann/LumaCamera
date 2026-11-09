import CoreImage
import Vision

/// 摇拍只根据中央40%的纹理估计平移，不追踪整幅背景；每次变换都用实际像素相关性复核。
/// 这不是语义识别或透视/旋转校正。中央主体离开、纹理太少或大幅移动时交给合成器回退单帧。
final class SlowShutterSubjectAlignment {
    private let context: CIContext
    private var reference: CGImage?
    private var referencePixels: [Double]?
    private var referenceExtent: CGRect?
    /// 最近一帧相对参考主体的平移；供摇拍背景方向模糊使用，不代表相机绝对运动。
    private(set) var lastShift = CGVector.zero
    init(context: CIContext) { self.context = context }

    func evaluate(_ image: CIImage) -> (image:CIImage,reliable:Bool,sharpness:Double) {
        let scale = min(1,640/max(image.extent.width,image.extent.height))
        let small = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            .transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let roi = CGRect(x:small.extent.width*0.3,y:small.extent.height*0.3,
                         width:small.extent.width*0.4,height:small.extent.height*0.4).integral
        guard let probe = Imaging.ownedCGImage(small,from:roi,context:context), let values = grayscale(probe) else {
            return (image,false,0)
        }
        let sharpness = edgeEnergy(values)
        guard let reference, let referencePixels, let referenceExtent else {
            guard correlation(values,values) != nil else { return (image,false,sharpness) }
            self.reference = probe; self.referencePixels = values; self.referenceExtent = image.extent
            return (image,correlation(values,values) != nil,sharpness)
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage:probe)
        guard (try? VNImageRequestHandler(cgImage:reference).perform([request])) != nil,
              let result = request.results?.first else { return (image,false,sharpness) }
        let shift = result.alignmentTransform
        // CG探针与CI坐标的纵轴约定可能不同；使用真实中央像素选择可验证的方向，而非盲套矩阵。
        var best: (Double,CGFloat,CGFloat)?
        for sx in [CGFloat(-1),1] { for sy in [CGFloat(-1),1] {
            let dx = shift.tx*sx, dy = shift.ty*sy
            guard dx.isFinite, dy.isFinite,
                  abs(dx/scale)<=referenceExtent.width*0.08, abs(dy/scale)<=referenceExtent.height*0.08,
                  let alignedProbe = Imaging.ownedCGImage(small.transformed(by:CGAffineTransform(translationX:dx,y:dy)),from:roi,context:context),
                  let pixels = grayscale(alignedProbe), let score = correlation(referencePixels,pixels) else { continue }
            if score > (best?.0 ?? -1) { best = (score,dx,dy) }
        } }
        guard let best, best.0 >= 0.75 else { lastShift = .zero; return (image,false,sharpness) }
        lastShift = CGVector(dx: best.1/scale, dy: best.2/scale)
        return (image.transformed(by:CGAffineTransform(translationX:best.1/scale,y:best.2/scale)),true,sharpness)
    }

    /// 96×96灰度统计只用于可靠性和清晰度，不降低最终照片分辨率。
    private func grayscale(_ image: CGImage) -> [Double]? {
        var bytes = [UInt8](repeating:0,count:96*96)
        let succeeded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data:buffer.baseAddress,width:96,height:96,bitsPerComponent:8,
                bytesPerRow:96,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.draw(image,in:CGRect(x:0,y:0,width:96,height:96)); return true
        }
        return succeeded ? bytes.map(Double.init) : nil
    }
    private func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let ma = a.reduce(0,+)/Double(a.count), mb = b.reduce(0,+)/Double(b.count)
        var aa = 0.0, bb = 0.0, ab = 0.0
        for i in a.indices { let x = a[i]-ma, y = b[i]-mb; aa += x*x; bb += y*y; ab += x*y }
        guard aa/Double(a.count)>16, bb/Double(b.count)>16 else { return nil }
        return ab/sqrt(aa*bb)
    }
    private func edgeEnergy(_ pixels: [Double]) -> Double {
        var sum = 0.0
        for y in 1..<95 { for x in 1..<95 {
            let i = y*96+x
            sum += abs(pixels[i]-pixels[i-1])+abs(pixels[i]-pixels[i-96])
        } }
        return sum/(94*94*2)
    }
}

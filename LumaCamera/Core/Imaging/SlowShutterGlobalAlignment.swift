import CoreImage

/// 手持慢门以静态纹理为锚点，补偿平移/小角度旋转/轻微透视；只缓存一张小参考图。
final class SlowShutterGlobalAlignment {
    private let context:CIContext
    private var reference:CIImage?
    init(context:CIContext) { self.context = context }

    func evaluate(_ image:CIImage)->(image:CIImage,reliable:Bool,sharpness:Double) {
        let extent = image.extent
        let normalized = image.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
        let scale = min(1,640/max(extent.width,extent.height))
        let small = normalized.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let bitmap = Imaging.ownedCGImage(small,from:small.extent,context:context) else { return (image,false,0) }
        let probe = CIImage(cgImage:bitmap)
        let edges = probe.applyingFilter("CIEdges",parameters:[kCIInputIntensityKey:1])
        let sharpness = Imaging.meanLuminance(edges,context:context)
        guard let reference else {
            guard sharpness>0.002 else { return (image,false,sharpness) }
            self.reference = probe.transformed(by:CGAffineTransform(scaleX:extent.width/CGFloat(bitmap.width),y:extent.height/CGFloat(bitmap.height)))
            return (image,true,sharpness)
        }
        guard let aligned = NightPhotoMerger.alignHandheldFrame(normalized,reference:reference,context:context) else { return (image,false,sharpness) }
        return (aligned.transformed(by:CGAffineTransform(translationX:extent.minX,y:extent.minY)),true,sharpness)
    }
}

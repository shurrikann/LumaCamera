import CoreImage
import UIKit

enum NightPreviewRenderer {
    static func exposureEV(mean:Double)->Double {
        guard mean.isFinite,mean>0 else { return 0 }
        return min(1.5,max(0,log2(0.08/max(0.004,mean))))
    }
    static func apply(_ image:CIImage,ev:Double)->CIImage {
        guard ev>0 else { return image }
        return image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
    }
}

struct NightPreviewReveal {
    let id:UUID
    let image:UIImage
    var progress:Double = 0
    var finalImage:UIImage?
}

import CoreImage

enum AstroTemporalMedian {
    /// Median of three group averages. For two groups it returns their mean;
    /// for one it returns the group unchanged.
    static func combine(_ images: [CIImage], extent: CGRect) -> CIImage? {
        guard let first = images.first else { return nil }
        if images.count >= 3 {
            let a = images[0], b = images[1], c = images[2]
            let abMin = a.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: b])
            let abMax = a.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b])
            let cMin = c.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: abMax])
            return abMin.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: cMin]).cropped(to: extent)
        }
        if images.count == 2 {
            let half = images[1].applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let halfBase = first.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            return halfBase.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: half]).cropped(to: extent)
        }
        return first.cropped(to: extent)
    }
}

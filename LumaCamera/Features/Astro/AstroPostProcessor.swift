import CoreImage

/// Deterministic finishing pass for stacked star images. It intentionally does
/// not attempt registration or dark-frame calibration.
enum AstroPostProcessor {
    static func enhanceStars(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.015,
                "inputSharpness": 0.40
            ])
            .applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.8,
                kCIInputIntensityKey: 0.35
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.035,
                kCIInputSaturationKey: 1.02,
                kCIInputBrightnessKey: 0.0
            ])
    }

    static func flattenBackground(_ image: CIImage, sky: CIImage? = nil) -> CIImage {
        guard let sky else { return image }
        let extent = image.extent
        let radius = max(24,min(extent.width,extent.height)*0.09)
        let background = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
        let average = background.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:extent)])
        // Remove part of the gradient, not the entire low-frequency sky signal.
        let baseline = average.clampedToExtent().cropped(to:extent)
        let gradient = AstroSignalProtection.difference(background,baseline)
            .applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0.2,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:0.2,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:0.2,w:0)])
        return AstroSignalProtection.difference(image,gradient)
            .applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:sky]).cropped(to:extent)
    }

    static func suppressHotPixels(_ image: CIImage) -> CIImage {
        // Without temporal evidence a compact star must not be classified as a bad pixel.
        image
    }

    static func fillTrailGaps(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.1])
    }

    static func enhanceTrails(_ image: CIImage) -> CIImage {
        // Spatial noise reduction already ran with a protected star mask.
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.04, kCIInputSaturationKey: 1.03,
            kCIInputBrightnessKey: 0.0
        ])
    }
}

import CoreImage

/// Resolution-relative effects use the same graph in live preview and photo encoding.
enum FilterAdjustmentRenderer {
    private static let channels = MetalImageKernels.general("chromaticShift")
    private static let bloomLayer = MetalImageKernels.color("bloomLayer")
    private static let addLight = MetalImageKernels.color("addLight")
    private static let alpha = MetalImageKernels.color("restoreAlpha")
    private static let highlights = MetalImageKernels.color("lights")
    // Preview supplies a fresh phase per frame so grain never forms a stationary
    // screen texture. Still images retain a stable phase for repeatable editing.
    private static let grain = MetalImageKernels.color("filmGrain")

    static func prepare() { _ = channels; _ = bloomLayer; _ = addLight; _ = alpha; _ = highlights; _ = grain }

    static func apply(_ settings: FilterAdjustments, to input: CIImage, grainPhase: Double = 0) -> CIImage {
        guard !settings.isNeutral else { return input }
        let extent = input.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return input }
        let scale = max(extent.width, extent.height) / 1200
        var image = input
        if settings[.temperature] != 0 || settings[.tint] != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 - settings[.temperature] * 25), y: CGFloat(settings[.tint] * 0.5))])
        }
        if settings[.exposure] != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings[.exposure]]) }
        if settings[.saturation] != 0 || settings[.brightness] != 0 || settings[.contrast] != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + settings[.saturation] / 100,
                kCIInputBrightnessKey: settings[.brightness] * 0.002,
                kCIInputContrastKey: pow(2, settings[.contrast] / 100)])
        }
        if settings[.highlights] != 0 || settings[.shadows] != 0 {
            let h = settings[.highlights] / 100, s = settings[.shadows] / 100
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25 + s * 0.12),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + (s + h) * 0.03),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + h * 0.12), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if settings[.fade] > 0 {
            let f = settings[.fade] / 100
            // Creamy aged paper: a gentle warm veil and lifted darks, while
            // retaining contrast between tones instead of a dense yellow cast.
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - f * 0.24, y: f * 0.14, z: f * 0.04, w: 0),
                "inputGVector": CIVector(x: f * 0.08, y: 1 - f * 0.26, z: f * 0.03, w: 0),
                "inputBVector": CIVector(x: f * 0.035, y: f * 0.04, z: 1 - f * 0.55, w: 0),
                "inputBiasVector": CIVector(x: f * 0.14, y: f * 0.13, z: f * 0.095, w: 0)])
        }
        let detail = settings[.detail]
        if detail < 0 {
            let sigma = -detail * 0.07 * scale
            let reduction = min(1, 2 / max(sigma, 0.001))
            image = image.transformed(by: CGAffineTransform(scaleX: reduction, y: reduction))
                .clampedToExtent().applyingGaussianBlur(sigma: sigma * reduction)
                .transformed(by: CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction)).cropped(to: extent)
        }
        if detail > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: detail * 0.015]) }
        if settings[.aberration] > 0 {
            let amount = settings[.aberration] * 0.0004
            image = channels?.apply(extent: extent, roiCallback: { _, rect in
                rect.insetBy(dx: -extent.width * amount * 2, dy: -extent.height * amount * 2)
            }, arguments: [image.clampedToExtent(), amount, CIVector(x: extent.midX, y: extent.midY)]) ?? image
        }
        // Only soft light is evaluated at reduced resolution. The sharp base image
        // and final photo remain at their original resolution.
        let lightReduction = min(1, 600 / max(extent.width, extent.height))
        let lightScale = scale * lightReduction
        func smallLight(_ source: CIImage) -> CIImage {
            source.transformed(by: CGAffineTransform(scaleX: lightReduction, y: lightReduction))
        }
        func restoreLight(_ light: CIImage) -> CIImage {
            light.transformed(by: CGAffineTransform(scaleX: 1 / lightReduction, y: 1 / lightReduction)).cropped(to: extent)
        }
        if settings[.softness] > 0 {
            let base = smallLight(image)
            let bloom = base.clampedToExtent().applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 10 * lightScale, kCIInputIntensityKey: settings[.softness] * 0.007]).cropped(to: base.extent)
            if let layer = bloomLayer?.apply(extent: base.extent, arguments: [bloom, base]) {
                image = addLight?.apply(extent: extent, arguments: [image, restoreLight(layer)]) ?? image
            }
        }
        if settings[.halation] > 0 {
            let base = smallLight(image)
            if let light = highlights?.apply(extent: base.extent, arguments: [base, settings[.halation] * 0.009]) {
                let near = light.clampedToExtent().applyingGaussianBlur(sigma: 3 * lightScale)
                let far = light.clampedToExtent().applyingGaussianBlur(sigma: 12 * lightScale)
                let halo = near.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: far, kCIInputTimeKey: 0.4])
                image = addLight?.apply(extent: extent, arguments: [image, restoreLight(halo)]) ?? image
            }
        }
        if settings[.grainSize] > 0 {
            image = grain?.apply(extent: extent, arguments: [image, max(0.5, scale * (0.6 + settings[.grainSize] * 0.035)),
                settings[.grainSize] * 0.0012, settings[.grainSaturation] / 100, grainPhase.isFinite ? grainPhase : 0]) ?? image
        }
        if settings[.vignette] > 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings[.vignette] * 0.018, kCIInputRadiusKey: min(extent.width, extent.height) * 0.65])
        }
        return (alpha?.apply(extent: extent, arguments: [image, input]) ?? image).cropped(to: extent)
    }
}

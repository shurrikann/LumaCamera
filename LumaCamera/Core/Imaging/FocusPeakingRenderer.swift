import CoreImage

/// Focus assistance is a display-only graph, never part of CaptureLook or PhotoEncoder.
enum FocusPeakingRenderer {
    private static let highlight = MetalImageKernels.color("focusPeak")
    static func apply(to display: CIImage, analysis source: CIImage) -> CIImage {
        let extent = display.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              source.extent.width > 0, source.extent.height > 0 else { return display }
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / source.extent.width, y: extent.height / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // Suppress isolated sensor noise before finding edges. Analyze the sensor
        // image so creative sharpening, grain and LUTs cannot create false peaks.
        let edges = normalized.clampedToExtent().applyingGaussianBlur(sigma: 0.65)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.8]).cropped(to: extent)
        return highlight?.apply(extent: extent, arguments: [display, edges]) ?? display
    }
}

import CoreImage
import CoreVideo

/// Renders the still-photo look into an encoder-ready pixel buffer for SDR/P3 movies.
final class VideoFrameFilterRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func renderLogLUT(source: CVPixelBuffer, destination: CVPixelBuffer, cube: LogLUTCube) {
        // Preserve encoded Log values through the cube; the writer's output tags are
        // switched to Rec.709 only when the LUT is actually baked.
        let sourceImage = CIImage(cvPixelBuffer: source)
        let filtered = cube.apply(to: sourceImage)
        context.render(filtered, to: destination, bounds: sourceImage.extent, colorSpace: nil)
    }

    func render(source: CVPixelBuffer, destination: CVPixelBuffer, look: CaptureLook,
                colorSpace: CGColorSpace, grainPhase: Double) {
        let sourceImage = CIImage(cvPixelBuffer: source, options: [.colorSpace: colorSpace])
        var frameLook = look
        frameLook.grainPhase = grainPhase
        let filteredImage = Imaging.filtered(sourceImage, look: frameLook)
        context.render(filteredImage, to: destination, bounds: sourceImage.extent, colorSpace: colorSpace)
    }
}

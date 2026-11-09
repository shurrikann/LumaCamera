import CoreImage
import CoreVideo

/// Renders the still-photo look into an encoder-ready pixel buffer for SDR/P3 movies.
final class VideoFrameFilterRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func renderLogLUT(source: CVPixelBuffer, destination: CVPixelBuffer, cube: LogLUTCube,
                      log2ToLog1: Bool = false) {
        let signalColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceImage = CIImage(cvPixelBuffer: source, options: [.colorSpace: signalColorSpace])
        let input = log2ToLog1 ? AppleLogLUTInput.log2ToLog1(sourceImage) : sourceImage
        let filtered = cube.apply(to: input)
        context.render(filtered, to: destination, bounds: sourceImage.extent, colorSpace: signalColorSpace)
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

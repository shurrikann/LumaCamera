import CoreImage

/// Empirical colour match to the user's same-source infrared reference, not a claim
/// about the reference app's internal algorithm. The imported LUT is kept unchanged.
enum ReferenceFilterCalibration {
    static func apply(_ style: FilmStyle, to image: CIImage) -> CIImage {
        guard style == .lut64f854a875 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.8705014051, y: 0.1273577982, z: 0.0234525729, w: 0),
            "inputGVector": CIVector(x: 0.0075246332, y: 0.9832630517, z: 0.0380165335, w: 0),
            "inputBVector": CIVector(x: 0.1015841025, y: -0.1034520963, z: 1.0677660505, w: 0)
        ]).cropped(to: image.extent)
    }
}

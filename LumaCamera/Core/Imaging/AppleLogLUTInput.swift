import CoreImage

/// Converts Apple Log 2 code values to Apple Log 1 (BT.2020) code values so a
/// Log1-authored creative LUT sees the input it expects.
enum AppleLogLUTInput {
    private static let kernel = MetalImageKernels.color("appleLog2ToAppleLog")

    static func log2ToLog1(_ image: CIImage) -> CIImage {
        guard let kernel else { return image }
        let r0 = CIVector(x: 1.028100938166, y: 0.098978817671, z: -0.127079755836)
        let r1 = CIVector(x: 0.002520341930, y: 1.170849643324, z: -0.173369985253)
        let r2 = CIVector(x: -0.022087573248, y: -0.064050383441, z: 1.086137956689)
        return kernel.apply(extent: image.extent, arguments: [image, r0, r1, r2])?.cropped(to: image.extent) ?? image
    }
}

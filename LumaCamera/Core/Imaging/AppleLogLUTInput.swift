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
    // CPU constants used by the one-time Log2→Log1 cube precomposition.
    private static let matrix: [[Float]] = [
        [1.028100938166, 0.098978817671, -0.127079755836],
        [0.002520341930, 1.170849643324, -0.173369985253],
        [-0.022087573248, -0.064050383441, 1.086137956689]
    ]

    static func log2CodeToLog1(_ rgb: (Float, Float, Float)) -> (Float, Float, Float) {
        let p = (min(max(rgb.0, 0), 1), min(max(rgb.1, 0), 1), min(max(rgb.2, 0), 1))
        func decode(_ v: Float) -> Float {
            let r0: Float = -0.05641088, rt: Float = 0.01, c: Float = 47.28711236
            let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
            let pt = c * (rt - r0) * (rt - r0)
            if v >= pt { return pow(2, (v - delta) / gamma) - beta }
            if v >= 0 { return sqrt(v / c) + r0 }
            return r0
        }
        func encode(_ v: Float) -> Float {
            let r0: Float = -0.05641088, rt: Float = 0.01, c: Float = 47.28711236
            let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
            let linear = max(v, 0)
            if linear >= rt { return gamma * log2(linear + beta) + delta }
            if linear >= r0 { return c * (linear - r0) * (linear - r0) }
            return 0
        }
        let linear = (decode(p.0), decode(p.1), decode(p.2))
        let bt = (
            matrix[0][0] * linear.0 + matrix[0][1] * linear.1 + matrix[0][2] * linear.2,
            matrix[1][0] * linear.0 + matrix[1][1] * linear.1 + matrix[1][2] * linear.2,
            matrix[2][0] * linear.0 + matrix[2][1] * linear.1 + matrix[2][2] * linear.2
        )
        return (min(max(encode(bt.0), 0), 1), min(max(encode(bt.1), 0), 1), min(max(encode(bt.2), 0), 1))
    }
}

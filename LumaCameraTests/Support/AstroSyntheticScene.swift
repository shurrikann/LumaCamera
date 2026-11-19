import CoreImage
import Foundation

struct AstroSyntheticScene {
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    struct Star {
        var position: CGPoint
        var magnitude: Double
        var color: SIMD3<Float> = SIMD3(0.92, 1, 0.86)
        var sigma: Double = 1.5
    }

    struct Satellite {
        var start: CGPoint
        var end: CGPoint
        var amplitude: Float = 0.65
        var frames: Set<Int>
    }

    let width = 512
    let height = 512
    var stars: [Star] = [
        .init(position: CGPoint(x: 32.5, y: 352.5), magnitude: 0.3),
        .init(position: CGPoint(x: 72.5, y: 95.5), magnitude: 0.1),
        .init(position: CGPoint(x: 143.5, y: 124.5), magnitude: 0.5),
        .init(position: CGPoint(x: 286.5, y: 104.5), magnitude: -0.55),
        .init(position: CGPoint(x: 398.5, y: 98.5), magnitude: 0.4),
        .init(position: CGPoint(x: 94.5, y: 261.5), magnitude: -0.22),
        .init(position: CGPoint(x: 213.5, y: 179.5), magnitude: -0.14),
        .init(position: CGPoint(x: 352.5, y: 226.5), magnitude: 0.1),
        .init(position: CGPoint(x: 433.5, y: 319.5), magnitude: 0.35),
        .init(position: CGPoint(x: 267.5, y: 397.5), magnitude: 0.22),
        .init(position: CGPoint(x: 118.5, y: 413.5), magnitude: 0.71),
        .init(position: CGPoint(x: 389.5, y: 439.5), magnitude: 0.62)
    ]
    var satellites: [Satellite] = []
    var hotPixels: [CGPoint] = []
    var includesGround = false
    var skyLevel: Float = 0.03
    var skyGradient: Float = 0.015
    var shotNoise: Float = 0.012
    var readNoise: Float = 0.003

    var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    func frame(_ index: Int, motion: CGAffineTransform = .identity,
               exposure: Float = 1, seed: UInt64 = 42) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            let sky = skyLevel + skyGradient * Float(y) / Float(height - 1)
            for x in 0..<width {
                let ground = includesGround && y < groundHeight(at: x)
                let level = ground ? ((x / 8 + y / 8).isMultiple(of: 2) ? Float(0.12) : 0.055) : sky
                let i = offset(x, y)
                pixels[i] = level
                pixels[i + 1] = level
                pixels[i + 2] = level
            }
        }
        for star in stars {
            let center = star.position.applying(motion)
            let radius = Int(ceil(4 * star.sigma))
            let x0 = max(0, Int(floor(center.x)) - radius), x1 = min(width, Int(floor(center.x)) + radius + 1)
            let y0 = max(0, Int(floor(center.y)) - radius), y1 = min(height, Int(floor(center.y)) + radius + 1)
            guard x0 < x1, y0 < y1 else { continue }
            let amplitude = pow(10, -0.4 * star.magnitude)
            for y in y0..<y1 {
                for x in x0..<x1 where !includesGround || y >= groundHeight(at: x) {
                    let dx = Double(x) + 0.5 - center.x, dy = Double(y) + 0.5 - center.y
                    let contribution = star.color * Float(amplitude * exp(-(dx * dx + dy * dy) / (2 * star.sigma * star.sigma)))
                    let i = offset(x, y)
                    pixels[i] += contribution.x
                    pixels[i + 1] += contribution.y
                    pixels[i + 2] += contribution.z
                }
            }
        }
        for track in satellites where track.frames.contains(index) {
            let start = track.start.applying(motion), end = track.end.applying(motion)
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            for y in 0..<height {
                for x in 0..<width where !includesGround || y >= groundHeight(at: x) {
                    let px = Double(x) + 0.5 - start.x, py = Double(y) + 0.5 - start.y
                    let t = (px * dx + py * dy) / lengthSquared
                    guard (0...1).contains(t) else { continue }
                    let distance = hypot(px - t * dx, py - t * dy)
                    guard distance < 3 else { continue }
                    let contribution = track.amplitude * Float(exp(-distance * distance / 2))
                    let i = offset(x, y)
                    for channel in 0..<3 { pixels[i + channel] += contribution }
                }
            }
        }
        var generator = GaussianGenerator(state: seed ^ ((UInt64(index) &+ 1) &* 0xD1B54A32D192ED03))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let signal = pixels[i + channel] * exposure
                if shotNoise == 0, readNoise == 0 {
                    pixels[i + channel] = signal
                } else {
                    // Gaussian shot-noise approximation with variance scaled by signal.
                    let deviation = sqrt(shotNoise * shotNoise * max(0, signal) + readNoise * readNoise)
                    pixels[i + channel] = signal + deviation * generator.next()
                }
            }
        }
        for pixel in hotPixels {
            let x = Int(pixel.x), y = Int(pixel.y)
            guard (0..<width).contains(x), (0..<height).contains(y) else { continue }
            for channel in 0..<3 { pixels[offset(x, y) + channel] += 2.25 }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: extent.size,
                       format: .RGBAf, colorSpace: Self.colorSpace)
    }

    func motion(dx: CGFloat, dy: CGFloat, rotation: CGFloat, pivot: CGPoint? = nil) -> CGAffineTransform {
        let center = pivot ?? CGPoint(x: extent.midX, y: extent.midY)
        let c = cos(rotation), s = sin(rotation)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: center.x + dx - c * center.x + s * center.y,
                                 ty: center.y + dy - s * center.x - c * center.y)
    }

    private func groundHeight(at x: Int) -> Int {
        52 + Int(12 * sin(Double(x) * 0.027)) + (x % 47 < 5 ? 9 : 0)
    }

    private func offset(_ x: Int, _ y: Int) -> Int { ((height - 1 - y) * width + x) * 4 }
}

private struct GaussianGenerator {
    var state: UInt64
    private var spare: Float?

    init(state: UInt64) { self.state = state }

    mutating func next() -> Float {
        if let spare { self.spare = nil; return spare }
        let radius = sqrt(-2 * log(uniform())), angle = 2 * Double.pi * uniform()
        spare = Float(radius * sin(angle))
        return Float(radius * cos(angle))
    }

    private mutating func uniform() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var bits = state
        bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
        return (Double((bits ^ (bits >> 31)) >> 11) + 0.5) / 9_007_199_254_740_992
    }
}

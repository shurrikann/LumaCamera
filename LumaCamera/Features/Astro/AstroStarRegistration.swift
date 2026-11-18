import CoreImage
import UIKit

/// Rigid star-pattern matching on a bounded float thumbnail. Only a transform
/// supported by several independent stars is applied to the original image.
enum AstroStarRegistration {
    static func aligned(_ frame: CIImage, to reference: CIImage, context: CIContext) -> CIImage {
        guard let transform = rigidTransform(reference: reference, frame: frame, context: context) else { return frame }
        // Transform the original linear, high-precision image, never an 8-bit copy.
        return frame.transformed(by: transform).cropped(to: reference.extent)
    }

    static func shiftedImage(_ source: CGImage, dx: CGFloat, dy: CGFloat) -> CGImage? {
        let image = CIImage(cgImage: source)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        return context.createCGImage(image.transformed(by: CGAffineTransform(translationX: dx, y: -dy)),
            from: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }

    static func rigidTransform(reference: CIImage, frame: CIImage, context: CIContext) -> CGAffineTransform? {
        let a = stars(reference, context: context), b = stars(frame, context: context)
        guard a.count >= 4, b.count >= 4 else { return nil }
        let tolerance = max(2, max(reference.extent.width, reference.extent.height) / 768 * 2)
        let maxShift = max(reference.extent.width, reference.extent.height) * 0.15
        var best: [(CGPoint, CGPoint)] = []
        var bestError = Double.infinity
        search: for i in 0..<a.count - 1 { for j in i + 1..<a.count {
            let ax = a[j].x - a[i].x, ay = a[j].y - a[i].y
            let length = hypot(ax, ay)
            guard length > tolerance * 8 else { continue }
            for k in 0..<b.count { for l in 0..<b.count where l != k {
                let bx = b[l].x - b[k].x, by = b[l].y - b[k].y
                guard abs(hypot(bx, by) - length) <= tolerance else { continue }
                let angle = atan2(ay, ax) - atan2(by, bx)
                guard abs(angle) <= .pi / 12 else { continue }
                let c = cos(angle), d = sin(angle)
                let tx = a[i].x - c * b[k].x + d * b[k].y
                let ty = a[i].y - d * b[k].x - c * b[k].y
                guard hypot(tx, ty) < maxShift else { continue }
                let t = CGAffineTransform(a: c, b: d, c: -d, d: c, tx: tx, ty: ty)
                var used = Set<Int>(), matches: [(CGPoint, CGPoint)] = [], error = 0.0
                for point in b {
                    let projected = point.applying(t)
                    var nearest: Int?, distance = tolerance
                    for n in a.indices where !used.contains(n) {
                        let value = hypot(a[n].x - projected.x, a[n].y - projected.y)
                        if value < distance { nearest = n; distance = value }
                    }
                    if let nearest { used.insert(nearest); matches.append((point, a[nearest])); error += distance * distance }
                }
                if matches.count > best.count || (matches.count == best.count && error < bestError) {
                    best = matches; bestError = error
                    if matches.count == min(a.count, b.count), error < Double(matches.count) * pow(Double(tolerance) * 0.4, 2) { break search }
                }
            } }
        } }
        guard best.count >= 4, best.count * 3 >= min(a.count, b.count) else { return nil }
        let count = CGFloat(best.count)
        let source = best.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.0.x / count, y: $0.y + $1.0.y / count) }
        let target = best.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.1.x / count, y: $0.y + $1.1.y / count) }
        var cross: CGFloat = 0, dot: CGFloat = 0
        for (p, q) in best {
            cross += (p.x - source.x) * (q.y - target.y) - (p.y - source.y) * (q.x - target.x)
            dot += (p.x - source.x) * (q.x - target.x) + (p.y - source.y) * (q.y - target.y)
        }
        let angle = atan2(cross, dot), c = cos(angle), d = sin(angle)
        return CGAffineTransform(a: c, b: d, c: -d, d: c,
            tx: target.x - c * source.x + d * source.y, ty: target.y - d * source.x - c * source.y)
    }

    static func stars(_ image: CIImage, context: CIContext) -> [CGPoint] {
        let extent = image.extent
        guard extent.width > 4, extent.height > 4 else { return [] }
        let scale = min(1, 768 / max(extent.width, extent.height))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(normalized.extent.width), height = Int(normalized.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(normalized, toBitmap: &pixels, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let values = (0..<width * height).map { i -> Float in
            let n = i * 4
            return max(0, 0.2126 * pixels[n] + 0.7152 * pixels[n + 1] + 0.0722 * pixels[n + 2])
        }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        let threshold = mean + max(0.002, sqrt(variance) * 2.5)
        var peaks: [(Float, Int, Int)] = []
        for y in 2..<height - 2 { for x in 2..<width - 2 {
            let value = values[y * width + x]
            guard value > threshold else { continue }
            var peak = true
            for dy in -1...1 { for dx in -1...1 where dy != 0 || dx != 0 {
                if values[(y + dy) * width + x + dx] > value { peak = false }
            } }
            if peak { peaks.append((value, x, y)) }
        } }
        peaks.sort { $0.0 > $1.0 }
        var found: [CGPoint] = []
        for (_, x, y) in peaks {
            var sum: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0
            for dy in -2...2 { for dx in -2...2 {
                let weight = CGFloat(max(0, values[(y + dy) * width + x + dx] - mean))
                sum += weight; sx += CGFloat(x + dx) * weight; sy += CGFloat(y + dy) * weight
            } }
            guard sum > 0 else { continue }
            let point = CGPoint(x: sx / sum / scale + extent.minX, y: extent.maxY - sy / sum / scale)
            guard !found.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 6 / scale }) else { continue }
            found.append(point)
            if found.count == 24 { break }
        }
        return found
    }

    static func estimateTranslation(reference: CIImage, frame: CIImage, context: CIContext) -> CGPoint? {
        guard let a = centroid(reference, context: context),
              let b = centroid(frame, context: context) else { return nil }
        let dx = min(max(a.x - b.x, -60), 60)
        let dy = min(max(a.y - b.y, -60), 60)
        guard abs(dx) > 0.25 || abs(dy) > 0.25 else { return nil }
        return CGPoint(x: dx, y: dy)
    }

    private static func centroid(_ image: CIImage, context: CIContext) -> CGPoint? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let scale = min(1, 480 / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(scaled.extent.width.rounded()))
        let height = max(1, Int(scaled.extent.height.rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &bytes, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var luma = [Double](repeating: 0, count: width * height)
        var mean = 0.0, square = 0.0
        for i in 0..<luma.count {
            let value = 0.2126 * Double(bytes[i * 4]) + 0.7152 * Double(bytes[i * 4 + 1]) + 0.0722 * Double(bytes[i * 4 + 2])
            luma[i] = value
            mean += value
            square += value * value
        }
        mean /= Double(max(1, luma.count))
        let variance = max(0, square / Double(max(1, luma.count)) - mean * mean)
        let threshold = mean + max(12, sqrt(variance) * 2.2)
        var count = 0, sumX = 0.0, sumY = 0.0, weight = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let value = luma[y * width + x]
                guard value > threshold else { continue }
                let w = value - threshold
                count += 1; weight += w
                sumX += Double(x) * w
                sumY += Double(y) * w
            }
        }
        guard count >= 6, weight > 0 else { return nil }
        return CGPoint(x: sumX / weight / scale, y: sumY / weight / scale)
    }
}

enum AstroCalibration {
    /// Approximate bias/dark calibration: estimate the low percentile and
    /// remove it from the linear frame. A real dark frame is not available.
    static func blackSubtracted(_ image: CIImage, context: CIContext) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let scale = min(1, 240 / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(scaled.extent.width.rounded()))
        let height = max(1, Int(scaled.extent.height.rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &bytes, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(width * height) {
            let value = Int(0.2126 * Double(bytes[i * 4]) + 0.7152 * Double(bytes[i * 4 + 1]) + 0.0722 * Double(bytes[i * 4 + 2]))
            histogram[min(255, max(0, value))] += 1
        }
        let target = max(1, (width * height) / 100)
        var accumulated = 0, black = 0
        for i in 0..<256 {
            accumulated += histogram[i]
            if accumulated >= target { black = i; break }
        }
        let bias = Double(black) / 255.0 * 0.25
        guard bias > 0.0005 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputBiasVector": CIVector(x: -bias, y: -bias, z: -bias, w: 0)
        ])
    }
}

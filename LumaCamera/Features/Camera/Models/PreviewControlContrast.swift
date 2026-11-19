import CoreGraphics
import Foundation

/// Small SDR copy of the displayed preview, in top-left image coordinates.
struct PreviewContrastSample {
    static let width = 64
    static let height = 96
    private static let linear: [Double] = (0...255).map { byte in
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static let orange = luminance(201, 101, 28)
    let pixels: [Double]

    static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        0.2126 * linear[Int(red)] + 0.7152 * linear[Int(green)] + 0.0722 * linear[Int(blue)]
    }

    static func render(_ image: CGImage) -> Self? {
        let width = Self.width, height = Self.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return Self(pixels: (0..<(width * height)).map {
            let index = $0 * 4
            return luminance(bytes[index], bytes[index + 1], bytes[index + 2])
        })
    }

    static func imageRegion(for control: CGRect, preview: CGRect, imageSize: CGSize) -> CGRect {
        guard !preview.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return .null }
        let overlap = control.insetBy(dx: -4, dy: -4).intersection(preview)
        guard !overlap.isEmpty else { return .null }
        let scale = max(preview.width / imageSize.width, preview.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGRect(x: (overlap.minX - preview.midX) / width + 0.5,
                      y: (overlap.minY - preview.midY) / height + 0.5,
                      width: overlap.width / width, height: overlap.height / height)
    }

    func minimumContrast(in region: CGRect, foreground: Double) -> Double? {
        guard !region.isEmpty else { return nil }
        let width = Self.width, height = Self.height
        let minX = max(0, Int(floor(region.minX * CGFloat(width))))
        let maxX = min(width, Int(ceil(region.maxX * CGFloat(width))))
        let minY = max(0, Int(floor(region.minY * CGFloat(height))))
        let maxY = min(height, Int(ceil(region.maxY * CGFloat(height))))
        let columns = min(3, maxX - minX), rows = min(3, maxY - minY)
        guard columns > 0, rows > 0 else { return nil }
        var minimum = 21.0
        for row in 0..<rows {
            let top = minY + row * (maxY - minY) / rows
            let bottom = minY + (row + 1) * (maxY - minY) / rows
            for column in 0..<columns {
                let left = minX + column * (maxX - minX) / columns
                let right = minX + (column + 1) * (maxX - minX) / columns
                var sum = 0.0
                for y in top..<bottom {
                    for x in left..<right {
                        sum += pixels[y * width + x]
                    }
                }
                let background = sum / Double((right - left) * (bottom - top))
                minimum = min(minimum, (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05))
            }
        }
        return minimum
    }
}

struct PreviewContrastHysteresis {
    private(set) var enhanced = false
    private var recoveryStartedAt: TimeInterval?

    mutating func update(contrast: Double?, target: Double, at time: TimeInterval) {
        guard let contrast else {
            self = Self()
            return
        }
        if contrast < target {
            enhanced = true
            recoveryStartedAt = nil
        } else if enhanced && contrast >= target + 0.5 {
            let start = recoveryStartedAt ?? time
            recoveryStartedAt = start
            if time - start >= 0.38 {
                self = Self()
            }
        } else {
            recoveryStartedAt = nil
        }
    }
}

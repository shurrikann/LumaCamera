import CoreImage
import UIKit
import XCTest
@testable import LumaCamera

final class AstroStarRegistrationTests: XCTestCase {
    func testRotationAndTranslationPreserveLinearHDRPrecision() throws {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let background = CIColor(cgColor: CGColor(colorSpace: linear, components: [0.12345, 0.12345, 0.12345, 1])!)
        let bright = CIColor(cgColor: CGColor(colorSpace: linear, components: [3, 3, 3, 1])!)
        var reference = CIImage(color: background).cropped(to: extent)
        let points = [CGPoint(x: 72, y: 95), CGPoint(x: 143, y: 68), CGPoint(x: 286, y: 104),
            CGPoint(x: 398, y: 76), CGPoint(x: 94, y: 261), CGPoint(x: 213, y: 179),
            CGPoint(x: 352, y: 226), CGPoint(x: 433, y: 319), CGPoint(x: 267, y: 397),
            CGPoint(x: 118, y: 413), CGPoint(x: 389, y: 439)]
        for point in points {
            let spot = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: point), "inputRadius0": 1, "inputRadius1": 3,
                "inputColor0": bright, "inputColor1": CIColor.clear
            ])!.outputImage!.cropped(to: extent)
            reference = spot.composited(over: reference)
        }
        let angle: CGFloat = 0.035, c = cos(angle), s = sin(angle)
        let movement = CGAffineTransform(a: c, b: s, c: -s, d: c,
            tx: 256 + 16 - c * 256 + s * 256, ty: 256 - 11 - s * 256 - c * 256)
        let frame = reference.transformed(by: movement).cropped(to: extent)
        let transform = try XCTUnwrap(AstroStarRegistration.rigidTransform(reference: reference, frame: frame, context: context))
        for point in points {
            let aligned = point.applying(movement).applying(transform)
            XCTAssertLessThan(hypot(aligned.x - point.x, aligned.y - point.y), 1.5)
        }
        let aligned = AstroStarRegistration.aligned(frame, to: reference, context: context)
        var floats = [Float](repeating: 0, count: 512 * 512 * 4)
        context.render(aligned, toBitmap: &floats, rowBytes: 512 * 16, bounds: extent, format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        XCTAssertGreaterThan(floats.max() ?? 0, 2, "HDR stars must not clip at 1.0")
        let center = (256 * 512 + 256) * 4
        XCTAssertEqual(floats[center], 0.12345, accuracy: 0.0003)
        var samples = [Double]()
        for _ in 0..<12 {
            let start = CACurrentMediaTime()
            XCTAssertNotNil(AstroStarRegistration.rigidTransform(reference: reference, frame: frame, context: context))
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        print("ASTRO-REGISTRATION samples=12 milliseconds=\(samples); 512px synthetic star pattern, not full-camera throughput")
    }

    func testBlankFrameDoesNotInventTransform() {
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertNil(AstroStarRegistration.rigidTransform(reference: image, frame: image, context: CIContext()))
    }
    func testTranslationMovesShiftedStarBackToReference() throws {
        let a = try dotImage(at: CGPoint(x: 100, y: 100))
        let b = try dotImage(at: CGPoint(x: 120, y: 112))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let shift = try XCTUnwrap(AstroStarRegistration.estimateTranslation(
            reference: CIImage(cgImage: a), frame: CIImage(cgImage: b), context: context))
        XCTAssertEqual(shift.x, -20, accuracy: 2)
        XCTAssertEqual(shift.y, -12, accuracy: 2)
        let shifted = try XCTUnwrap(AstroStarRegistration.shiftedImage(b, dx: shift.x, dy: shift.y))
        let point = try brightestPoint(shifted, width: 512, height: 512)
        XCTAssertEqual(point.x, 100, accuracy: 6)
        XCTAssertEqual(point.y, 100, accuracy: 6)
    }

    private func dotImage(at point: CGPoint) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            UIColor.white.setFill(); ctx.fill(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        }.cgImage)
    }

    private func brightestPoint(_ image: CGImage, width: Int, height: Int) throws -> CGPoint {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best = 0, bx = 0, by = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let value = Int(bytes[index * 4]) + Int(bytes[index * 4 + 1]) + Int(bytes[index * 4 + 2])
                if value > best { best = value; bx = x; by = y }
            }
        }
        return CGPoint(x: bx, y: by)
    }
}

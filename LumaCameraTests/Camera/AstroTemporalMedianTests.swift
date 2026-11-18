import CoreImage
import UIKit
import XCTest
@testable import LumaCamera

final class AstroTemporalMedianTests: XCTestCase {
    func testMedianRejectsSingleGroupSatelliteTrail() throws {
        let a = try image(lineRow: nil)
        let b = try image(lineRow: nil)
        let c = try image(lineRow: 12)
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let result = try XCTUnwrap(AstroTemporalMedian.combine([CIImage(cgImage: a), CIImage(cgImage: b), CIImage(cgImage: c)], extent: extent))
        let pixels = try render(result, width: 64, height: 64)
        // The isolated bright row from group C must be rejected.
        let satellite = luminance(pixels, x: 32, y: 12)
        XCTAssertLessThan(satellite, 40)
        // The star present in all groups must survive.
        let star = luminance(pixels, x: 32, y: 32)
        XCTAssertGreaterThan(star, 180)
    }

    private func image(lineRow: Int?) throws -> CGImage {
        let size = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 30, y: 30, width: 5, height: 5))
        if let lineRow {
            context.fill(CGRect(x: 0, y: lineRow, width: size, height: 2))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func render(_ image: CIImage, width: Int, height: Int) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    private func luminance(_ bytes: [UInt8], x: Int, y: Int) -> Int {
        let i = (y * 64 + x) * 4
        return (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
    }
}

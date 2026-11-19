import SwiftUI
import XCTest
@testable import LumaCamera

final class CaptureShutterFaceTests: XCTestCase {
    @MainActor func testCaptureColorsAndLoadingStayInsideFixedShutterFrame() throws {
        let start = ContinuousClock.now
        var samples = 0
        for kind in [CaptureShutterFace.Kind.photo, .video] {
            for center in [CaptureShutterFace.Center.none, .stop, .loading, .stop, .none] {
                let renderer = ImageRenderer(content: CaptureShutterFace(kind: kind, center: center))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 76)
                XCTAssertEqual(image.height, 76)
                let base = try pixel(in: image, x: 60, y: 38)
                let square = try pixel(in: image, x: 30, y: 30)
                assertColor(base, red: kind == .video)
                assertColor(square, red: center == .none ? kind == .video : kind == .photo)
                samples += 1
            }
        }
        print("SHUTTER-FACE samples=\(samples) elapsed=\(ContinuousClock.now - start)")
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    private func assertColor(_ rgba: [UInt8], red: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(rgba[0], 200, file: file, line: line)
        if red {
            XCTAssertLessThan(rgba[1], 115, file: file, line: line)
            XCTAssertLessThan(rgba[2], 115, file: file, line: line)
        } else {
            XCTAssertGreaterThan(rgba[1], 230, file: file, line: line)
            XCTAssertGreaterThan(rgba[2], 230, file: file, line: line)
        }
    }
}

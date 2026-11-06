import XCTest
import CoreImage
import ImageIO
@testable import LumaCamera

/// 使用有上下方向标记的像素验证方向，避免仅检查宽高而漏掉倒置、侧转。
final class FrontPhotoOrientationTests: XCTestCase {
    private let context = CIContext()

    func testFrontCropAxisFollowsCaptureRotationWithoutChangingSensorChoice() {
        for landscape in [false, true] {
            for angle: CGFloat in [0, 180, 360, -180] {
                XCTAssertEqual(CaptureOrientation.frontPhotoLandscape(sensorLandscape: landscape, captureAngle: angle), landscape)
            }
            for angle: CGFloat in [90, 270, -90, 450] {
                XCTAssertEqual(CaptureOrientation.frontPhotoLandscape(sensorLandscape: landscape, captureAngle: angle), !landscape)
            }
        }
    }

    private func assertUpright(_ image: CIImage, file: StaticString = #filePath, line: UInt = #line) {
        func sample(_ y: CGFloat) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: image.extent.midX, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let top = sample(image.extent.maxY - 4), bottom = sample(image.extent.minY + 4)
        XCTAssertGreaterThan(top[0], 200, file: file, line: line)
        XCTAssertLessThan(top[2], 40, file: file, line: line)
        XCTAssertGreaterThan(bottom[2], 200, file: file, line: line)
        XCTAssertLessThan(bottom[0], 40, file: file, line: line)
    }

    func testNativeFrontPreviewAndPhotoKeepTopInBothSystemFramings() {
        for size in [CGSize(width: 80, height: 120), CGSize(width: 120, height: 80)] {
            let rect = CGRect(origin: .zero, size: size)
            let blue = CIImage(color: .blue).cropped(to: rect)
            // 夹具像素已经朝上：解码后的横竖画幅不得再固定侧转，真机快门方向由协调器提供。
            let upright = CIImage(color: .red).cropped(to: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)).composited(over: blue)
            let photo = CaptureOrientation.nativeFrontPhotoFrame(upright)
            let preview = CaptureOrientation.nativeFrontPreviewFrame(upright).oriented(.upMirrored)
            assertUpright(photo); assertUpright(preview)
            XCTAssertEqual(photo.extent.size, size)
            XCTAssertEqual(preview.extent, photo.extent)
        }
    }

    func testIntrinsicCorrectionRestoresBothAxesWithoutChangingUprightPixels() {
        let base = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 160))
        let upright = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 80, width: 120, height: 80)).composited(over: base)
        for (sx, sy) in [(CGFloat(16.0/9), CGFloat(1)), (CGFloat(1), CGFloat(16.0/9))] {
            let stretched = upright.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let corrected = CaptureOrientation.correctingIntrinsicScale(stretched, focalX: Float(1000*sx), focalY: Float(1000*sy))
            XCTAssertEqual(corrected.extent.width, 120, accuracy: 0.001)
            XCTAssertEqual(corrected.extent.height, 160, accuracy: 0.001)
            assertUpright(corrected)
        }
        for values in [(Float.nan, Float(100)), (Float(0), Float(100)), (Float(1000), Float(999))] {
            XCTAssertEqual(CaptureOrientation.correctingIntrinsicScale(upright, focalX: values.0, focalY: values.1).extent, upright.extent)
        }
    }

    func testEncodedFileAndPreviewKeepSameAlreadyDecodedPixelDirection() throws {
        for landscape in [false, true] {
            let size = landscape ? CGSize(width: 160, height: 120) : CGSize(width: 120, height: 160)
            let rect = CGRect(origin: .zero, size: size)
            let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
                .composited(over: CIImage(color: .blue).cropped(to: rect))
                .settingProperties([kCGImagePropertyOrientation as String: 6,
                                    kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6]])
            for format in [PhotoFileFormat.jpeg, .heif] {
                let photo = try PhotoEncoder.encode(source: image, raw: nil, look: CaptureLook(landscape: landscape),
                                                    options: PhotoOptions(format: format), context: context)
                let data = try XCTUnwrap(photo.resources.first?.data)
                let decoded = try XCTUnwrap(CIImage(data: data, options: [.applyOrientationProperty: true]))
                let preview = try XCTUnwrap(CIImage(image: photo.preview))
                assertUpright(decoded); assertUpright(preview)
                XCTAssertEqual(decoded.extent.size, preview.extent.size)
            }
        }
    }
}

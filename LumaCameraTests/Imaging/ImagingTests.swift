import XCTest
import CoreImage
import UIKit
import Combine
@testable import LumaCamera

final class ImagingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func testPortraitCropsStayCenteredAndInsideSource() {
        let extent = CGRect(x: 50, y: 80, width: 900, height: 1200)
        let source = CIImage(color: .white).cropped(to: extent)
        for ratio in FrameRatio.allCases {
            let crop = ratio.crop(source).extent
            // Core Image expands each fractional edge outwards: total width error is less than two pixels.
            XCTAssertEqual(crop.width, crop.height * ratio.portraitRatio, accuracy: 2.00001)
            XCTAssertEqual(crop.midX, extent.midX, accuracy: 0.5)
            XCTAssertEqual(crop.midY, extent.midY, accuracy: 0.5)
            XCTAssertTrue(extent.contains(crop))
        }
    }

    func testLandscapeCropsAreReciprocalAndStayInsideSource() {
        let extent = CGRect(x: 50, y: 80, width: 1200, height: 900)
        let source = CIImage(color: .white).cropped(to: extent)
        for ratio in FrameRatio.photoOptions {
            let crop = ratio.crop(source, landscape: true).extent
            XCTAssertEqual(crop.width / crop.height, ratio.landscapeRatio, accuracy: max(1, ratio.landscapeRatio) * 0.5 / crop.height + 0.00001)
            XCTAssertEqual(crop.midX, extent.midX, accuracy: 0.5)
            XCTAssertEqual(crop.midY, extent.midY, accuracy: 0.5)
            XCTAssertTrue(extent.contains(crop))
        }
    }

    func testZeroIntensityPreservesOriginalPixels() {
        let source = CIImage(color: CIColor(red: 0.6, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let expected = pixel(source)
        for style in FilmStyle.allCases {
            let actual = pixel(style.apply(to: source, intensity: 0))
            for channel in 0..<4 { XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 1, "\(style) channel \(channel)") }
        }
    }

    func testMonochromeProducesEqualColorChannels() {
        let source = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let baseline = pixel(FilmStyle.mono.apply(to: source, intensity: 0.8))
        let result = pixel(FilmStyle.mono.apply(to: source, intensity: 1))
        XCTAssertEqual(Int(result[0]), Int(result[1]), accuracy: 2)
        XCTAssertEqual(Int(result[1]), Int(result[2]), accuracy: 2)
        XCTAssertEqual(result[3], 255)
        XCTAssertGreaterThan(Int(result[0]) - Int(result[1]), -2)
        XCTAssertGreaterThanOrEqual(abs(Int(result[0]) - Int(result[1])), abs(Int(baseline[0]) - Int(baseline[1])))
    }

    func testAllFiltersRenderEveryRatioAndBorderAddsCanvas() throws {
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        for ratio in FrameRatio.allCases {
            for style in FilmStyle.allCases {
                // 每个矩阵项释放 UIKit/CI 临时对象；保留全部滤镜×比例与边框覆盖。
                try autoreleasepool {
                let image = try XCTUnwrap(Imaging.render(source, look: CaptureLook(style: style, intensity: 0.8, ratio: ratio), context: context))
                XCTAssertEqual(image.size.width / image.size.height, ratio.portraitRatio, accuracy: 0.002)
                let framed = try XCTUnwrap(Imaging.render(source, look: CaptureLook(style: style, intensity: 0.8, ratio: ratio, border: true), context: context))
                XCTAssertGreaterThan(framed.size.width, image.size.width)
                XCTAssertGreaterThan(framed.size.height, image.size.height)
                }
                context.clearCaches()
            }
        }
    }

    func testLandscapeLookRendersTheRequestedOrientation() throws {
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        for ratio in FrameRatio.photoOptions {
            let image = try XCTUnwrap(Imaging.render(source, look: CaptureLook(style: .original, ratio: ratio, landscape: true), context: context))
            XCTAssertEqual(image.size.width / image.size.height, ratio.landscapeRatio, accuracy: max(1, ratio.landscapeRatio) * 0.5 / image.size.height + 0.00001)
        }
    }

    func testRawOutputKeepsSensorOrientationInsteadOfAspectCrop() {
        let landscapeLook = CaptureLook(style: .original, ratio: .standard, landscape: true)
        let rawLook = landscapeLook.forOutput(.raw)
        XCTAssertFalse(rawLook.landscape)
        XCTAssertEqual(rawLook.ratio, .standard)
    }

    func testHistogramCountsTranslatedBlackAndWhiteImage() {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 20, y: 30, width: 64, height: 64))
        let white = CIImage(color: .white).cropped(to: CGRect(x: 52, y: 30, width: 32, height: 64))
        let bins = Imaging.histogram(white.composited(over: black), context: context)
        XCTAssertEqual(bins.count, 128)
        XCTAssertEqual(bins[0], 1, accuracy: 0.01)
        XCTAssertEqual(bins[127], 1, accuracy: 0.01)
        XCTAssertEqual(bins.filter { $0 > 0.01 }.count, 2)
        XCTAssertTrue(bins.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    private func pixel(_ image: CIImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return result
    }
}

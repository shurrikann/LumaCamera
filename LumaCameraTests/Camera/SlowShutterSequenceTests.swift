import XCTest
import CoreImage
@testable import LumaCamera

final class SlowShutterSequenceTests: XCTestCase {
    func testFourPresetsUseCorrectSequenceExposureAndBlend() {
        let trails = SlowShutterPreset.lightTrails.sequenceSpec
        XCTAssertEqual(trails?.frameCount, 96)
        XCTAssertEqual(trails?.captureDuration, 10)
        XCTAssertEqual(trails?.blend, .handheldAlignedLighten)
        let water = SlowShutterPreset.silkyWater.sequenceSpec
        XCTAssertEqual(water?.frameCount, 64)
        XCTAssertEqual(water?.captureDuration, 8)
        XCTAssertEqual(water?.blend, .handheldAlignedAverage)
        let stars = SlowShutterPreset.starTrails.sequenceSpec
        XCTAssertEqual(stars?.frameCount, 512)
        XCTAssertEqual(stars?.captureDuration, 120)
        XCTAssertEqual(stars?.blend, .lighten)
        let motion = SlowShutterPreset.motionBlur.sequenceSpec
        XCTAssertEqual(motion?.frameCount, 24)
        XCTAssertEqual(motion?.captureDuration, 2)
        XCTAssertEqual(motion?.blend, .handheldAlignedAverage)
        XCTAssertTrue(SlowShutterPreset.starTrails.usesStreamingComposition)
        XCTAssertTrue(SlowShutterPreset.motionBlur.usesStreamingComposition)
        XCTAssertTrue(SlowShutterPreset.lightTrails.usesStreamingComposition)
        XCTAssertEqual(SlowShutterPreset.panning.sequenceSpec?.blend,.subjectAlignedAverage)
    }

    func testLightenKeepsBrightestChannels() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let composer = SlowShutterComposer(blend: .lighten, context: context)
        composer.add(red)
        composer.add(green)
        let result = try XCTUnwrap(composer.result)
        let pixel = try render(result, context: context)
        XCTAssertEqual(pixel[0], 255, accuracy: 2)
        XCTAssertEqual(pixel[1], 255, accuracy: 2)
        XCTAssertEqual(pixel[2], 0, accuracy: 2)
        XCTAssertEqual(pixel[3], 255, accuracy: 2)
    }

    func testAverageBlendsFrames() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let composer = SlowShutterComposer(blend: .average, context: context)
        composer.add(red)
        composer.add(blue)
        let result = try XCTUnwrap(composer.result)
        let pixel = try render(result, context: context)
        XCTAssertEqual(pixel[0], pixel[2], accuracy: 2)
        // 线性工作空间的 0.5 编码为 sRGB 后约 188，不再接受透明度重复预乘后的暗值。
        XCTAssertEqual(pixel[0],188,accuracy:3)
        XCTAssertEqual(pixel[1], 0, accuracy: 3)
        XCTAssertEqual(pixel[3], 255, accuracy: 3)
    }

    func testStreamingLightenRetainsMovingBrightPointsAcross120Frames() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let composer = SlowShutterComposer(blend: .lighten, context: context, materializeFrames: true)
        let extent = CGRect(x: 0, y: 0, width: 128, height: 32)
        let start = CACurrentMediaTime()
        for index in 0..<120 {
            let black = CIImage(color: .black).cropped(to: extent)
            let point = CIImage(color: .white).cropped(to: CGRect(x: index, y: 0, width: 1, height: 1))
            XCTAssertTrue(autoreleasepool { composer.add(point.composited(over: black)) })
        }
        let result = try XCTUnwrap(composer.result)
        for index in [0, 59, 119] {
            let sample = result.transformed(by: CGAffineTransform(translationX: -CGFloat(index), y: 0))
            XCTAssertEqual(try render(sample, context: context)[0], 255, accuracy: 2)
        }
        XCTAssertEqual(composer.frameCount, 120)
        print("SLOW-STREAM-ALGORITHM samples=120 size=128x32 seconds=\(CACurrentMediaTime() - start)")
    }

    func testStreamingAverageMatchesLazyAverageAndRejectsInvalidFrame() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let stream = SlowShutterComposer(blend: .average, context: context, materializeFrames: true)
        let lazy = SlowShutterComposer(blend: .average, context: context)
        for index in 0..<8 {
            let image = CIImage(color: CIColor(red: CGFloat(index) / 7, green: 0.3, blue: 0.7))
                .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            XCTAssertTrue(stream.add(image)); lazy.add(image)
        }
        let actual = try render(XCTUnwrap(stream.result), context: context)
        let expected = try render(XCTUnwrap(lazy.result), context: context)
        for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 2) }
        XCTAssertFalse(stream.add(CIImage.empty()))
        XCTAssertEqual(stream.frameCount, 8)
    }

    private func render(_ image: CIImage, context: CIContext) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pixel
    }
}

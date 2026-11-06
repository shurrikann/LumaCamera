import XCTest
import CoreImage
import UIKit
import Combine
@testable import LumaCamera

final class FilterStrengthTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private func pixel(_ image: CIImage, context: CIContext) -> [Float] {
        var bytes = [Float](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: image.extent.midX.rounded(.down), y: image.extent.midY.rounded(.down), width: 1, height: 1), format: .RGBAf, colorSpace: space)
        }
        return bytes
    }

    func testStrengthIsUniformThroughEightyWithoutChangingAlpha() {
        for software in [false, true] {
            let context = CIContext(options: [.useSoftwareRenderer: software])
            for alpha in [CGFloat(1), 0.4] {
                let source = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.1, alpha: alpha)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
                let original = pixel(source, context: context)
                for style in FilmStyle.allCases {
                    let reference = pixel(style.referenceImage(to: source), context: context)
                    for intensity in [0.01, 0.1, 0.25, 0.5, 0.75, 0.8] {
                        let actual = pixel(style.apply(to: source, intensity: intensity), context: context)
                        for channel in 0..<4 {
                            if style == .mono && intensity > 0.8 && channel < 3 {
                                XCTAssertEqual(actual[channel], actual[0], accuracy: 0.003, "Mono must remain neutral at (intensity), software (software)")
                                continue
                            }
                            let factor = Float(FilmStyle.effectStrength(for: intensity))
                            let raw = original[channel] + (reference[channel] - original[channel]) * factor
                            // HDR 预览不做 SDR 截断；负值必须钳到0，否则会整屏发黑。
                            let expected = channel < 3 ? max(0, raw) : raw
                            XCTAssertTrue(actual[channel].isFinite)
                            XCTAssertEqual(actual[channel], expected, accuracy: 0.003, "\(style), intensity \(intensity), software \(software)")
                        }
                    }
                }
            }
        }
    }

    func testEffectStrengthCapsAtOnePointThree() {
        XCTAssertEqual(FilmStyle.effectStrength(for: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: 0.8), 1, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: 1), 1.3, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: 0.9), 1.15, accuracy: 0.0001)
        XCTAssertEqual(FilmStyle.effectStrength(for: 0.5), 0.625, accuracy: 0.0001)
    }

    func testFullStrengthAddsSafeBoostInsteadOfNegativeExtrapolation() throws {
        let context = CIContext()
        for alpha in [CGFloat(1), 0.4] {
            let source = CIImage(color: CIColor(red: 0.65, green: 0.4, blue: 0.2, alpha: alpha)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            for style in FilmStyle.availableStyles where style != .original {
                let reference = pixel(style.referenceImage(to: source), context: context)
                let atReference = pixel(style.apply(to: source, intensity: 0.8), context: context)
                let boosted = pixel(style.apply(to: source, intensity: 1), context: context)
                for channel in 0..<3 {
                    XCTAssertEqual(atReference[channel], reference[channel], accuracy: 0.004, style.title)
                    XCTAssertTrue(boosted[channel].isFinite)
                    XCTAssertGreaterThanOrEqual(boosted[channel], 0, "全强度不能产生负色：\(style.title)")
                }
                XCTAssertEqual(boosted[3], atReference[3], accuracy: 0.001, "全强度必须保持 alpha")
            }
        }
    }

    func testAboveEightyStillChangesLookWithoutNegativeChannels() {
        let context = CIContext()
        let source = CIImage(color: CIColor(red: 0.65, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var previous = pixel(FilmStyle.food.apply(to: source, intensity: 0.8), context: context)
        var changed = false
        for strength in [0.85, 0.9, 0.95, 1.0] {
            let value = pixel(FilmStyle.food.apply(to: source, intensity: strength), context: context)
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(value[channel], 0)
                if abs(value[channel] - previous[channel]) > 0.001 { changed = true }
            }
            previous = value
        }
        XCTAssertTrue(changed, "80%以上必须仍能看出浓度变化")
    }

    func testInvalidAndOutOfRangeStrengthsHaveStableEndpoints() {
        let context = CIContext()
        let source = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        for style in FilmStyle.allCases {
            for value in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
                let actual = pixel(style.apply(to: source, intensity: value), context: context)
                let expected = pixel(source, context: context)
                for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.0001) }
            }
            let actual = pixel(style.apply(to: source, intensity: 2), context: context)
            let expected = pixel(style.apply(to: source, intensity: 1), context: context)
            for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.0001) }
        }
    }

    @MainActor
    func testRapidStrengthChangesPublishOnlyTheLatestLook() async throws {
        #if targetEnvironment(simulator)
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.start()
        defer { model.camera.stop() }
        for _ in 0..<100 {
            if model.camera.ready && model.camera.preview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.camera.ready)
        let context = CIContext()
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        let expectedImage = try XCTUnwrap(Imaging.render(source, look: CaptureLook(style: .amber, intensity: 0.37), context: context))
        let expected = pixel(try XCTUnwrap(CIImage(image: expectedImage)), context: context)
        let latestFrame = expectation(description: "Latest slider look displayed")
        latestFrame.assertForOverFulfill = false
        var observed = 0
        let subscription = model.camera.$preview.dropFirst().compactMap { $0 }.sink { image in
            guard let source = CIImage(image: image) else { XCTFail("No preview pixels"); return }
            observed += 1
            let actual = self.pixel(source, context: context)
            for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.003, "Outdated preview after slider burst") }
            latestFrame.fulfill()
        }
        defer { subscription.cancel() }
        model.style = .mono
        for value in 0..<30 { model.intensity = Double(value) / 29 }
        model.style = .amber
        model.intensity = 0.37
        await fulfillment(of: [latestFrame], timeout: 5)
        XCTAssertGreaterThan(observed, 0)
        #endif
    }
}

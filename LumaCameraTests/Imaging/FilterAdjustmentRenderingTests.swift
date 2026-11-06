import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class FilterAdjustmentRenderingTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private func source(size: CGSize = CGSize(width: 120, height: 160), alpha: CGFloat = 1) -> CIImage {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: 0.22, green: 0.35, blue: 0.55, alpha: alpha).setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.98, green: 0.9, blue: 0.74, alpha: alpha).setFill(); UIRectFill(CGRect(x: size.width * 0.3, y: size.height * 0.2, width: size.width * 0.5, height: size.height * 0.45))
            UIColor(red: 0.7, green: 0.17, blue: 0.12, alpha: alpha).setFill(); UIRectFill(CGRect(x: size.width * 0.1, y: size.height * 0.6, width: size.width * 0.5, height: size.height * 0.2))
        }
        return CIImage(image: image)!
    }
    private func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 48 * 64 * 4)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 48 / image.extent.width, y: 64 / image.extent.height))
        data.withUnsafeMutableBytes { context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: 48 * 4, bounds: CGRect(x: 0, y: 0, width: 48, height: 64), format: .RGBA8, colorSpace: space) }
        return data
    }
    func testEveryAdjustmentChangesPixelsWhileNeutralPreservesOriginal() {
        for software in [false, true] {
            let context = CIContext(options: [.useSoftwareRenderer: software])
            let input = source()
            let original = pixels(input, context: context)
            XCTAssertEqual(pixels(FilterAdjustmentRenderer.apply(FilterAdjustments(), to: input), context: context), original)
            for parameter in FilterParameter.allCases where parameter != .strength {
                var settings = FilterAdjustments()
                settings[parameter] = parameter == .exposure ? 1 : 75
                if parameter == .grainSaturation { settings[.grainSize] = 75 }
                let baseline: CIImage
                if parameter == .grainSaturation {
                    var monoGrain = FilterAdjustments(); monoGrain[.grainSize] = 75
                    baseline = FilterAdjustmentRenderer.apply(monoGrain, to: input)
                } else { baseline = input }
                let result = FilterAdjustmentRenderer.apply(settings, to: input)
                XCTAssertEqual(result.extent, input.extent)
                XCTAssertNotEqual(pixels(result, context: context), pixels(baseline, context: context), "No effect: \(parameter), software=\(software)")
            }
            var blur = FilterAdjustments(); blur[.detail] = -80
            XCTAssertNotEqual(pixels(FilterAdjustmentRenderer.apply(blur, to: input), context: context), original)
        }
    }
    func testCombinedEffectsPreserveAlphaExtentAndRAWResources() throws {
        let context = CIContext()
        let bounds = CGRect(x: 7, y: 11, width: 120, height: 160)
        let input = CIImage(color: CIColor(red: 0.7, green: 0.4, blue: 0.2, alpha: 0.4)).cropped(to: bounds)
        var settings = FilterAdjustments()
        for p in FilterParameter.allCases where p != .strength { settings[p] = p.range.upperBound * 0.3 }
        let output = FilterAdjustmentRenderer.apply(settings, to: input)
        XCTAssertEqual(output.extent, bounds)
        let rgba = pixels(output, context: context)
        for index in stride(from: 3, to: rgba.count, by: 4) { XCTAssertEqual(Int(rgba[index]), 102, accuracy: 1) }
        let raw = Data([1, 4, 7, 8])
        let look = CaptureLook(style: .leicaM9, adjustments: settings)
        let photo = try PhotoEncoder.encode(source: source(), raw: raw, look: look, options: PhotoOptions(format: .rawJPEG), context: context)
        XCTAssertEqual(photo.resources[1].data, raw)
        let onlyRAW = try PhotoEncoder.encode(source: source(), raw: raw, look: look, options: PhotoOptions(format: .raw), context: context)
        let cleanRAW = try PhotoEncoder.encode(source: source(), raw: raw, look: CaptureLook(), options: PhotoOptions(format: .raw), context: context)
        XCTAssertEqual(onlyRAW.preview.pngData(), cleanRAW.preview.pngData())
    }
    #if targetEnvironment(simulator)
    @MainActor func testLatestEditedPreviewMatchesCapturedTIFFAndKeepsSettingsAfterCapture() async throws {
        let model = AppDependencies.makeCameraModel(automaticallySave: false)
        model.camera.start(); defer { model.camera.stop() }
        for _ in 0..<200 { if model.camera.ready && model.camera.preview != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        model.style = .leicaM9; model.photoFormat = .tiff
        for i in 0..<40 { model.filterParameterBinding(.temperature).wrappedValue = Double(i) }
        var settings = model.filterAdjustments
        for p in FilterParameter.allCases where p != .strength && p != .temperature { settings[p] = p == .exposure ? 0.2 : 12 }
        model.filterAdjustments = settings
        let look = model.effectiveCaptureLook
        let context = CIContext()
        let source = try XCTUnwrap(CIImage(image: DemoImageFactory.make()))
        let expected = try XCTUnwrap(Imaging.render(source, look: look, context: context))
        for _ in 0..<300 {
            if let current = model.camera.preview,
               pixels(CIImage(image: current)!, context: context) == pixels(CIImage(image: expected)!, context: context) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let current = try XCTUnwrap(model.camera.preview)
        XCTAssertEqual(pixels(CIImage(image: current)!, context: context), pixels(CIImage(image: expected)!, context: context))
        model.takePhoto()
        for _ in 0..<400 { if model.library.lastPhoto != nil { break }; try await Task.sleep(for: .milliseconds(30)) }
        let photo = try XCTUnwrap(model.library.lastPhoto)
        XCTAssertEqual(pixels(CIImage(image: photo)!, context: context), pixels(CIImage(image: expected)!, context: context))
        XCTAssertEqual(model.filterAdjustments, settings)
    }
    #endif
}

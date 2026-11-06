import XCTest
import CoreImage
import UIKit
@testable import LumaCamera

final class FilterTextureTests: XCTestCase {
    private let context = CIContext()
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private func samples(_ image: CIImage, bounds: CGRect) -> [Float] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var data = [Float](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: space) }
        return data
    }
    func testGrainChangesBetweenPreviewFramesButStillEditsAreRepeatable() {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
        let input = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: bounds)
        var recipe = FilterAdjustments(); recipe[.grainSize] = 60
        let first = samples(FilterAdjustmentRenderer.apply(recipe, to: input, grainPhase: 73), bounds: bounds)
        let next = samples(FilterAdjustmentRenderer.apply(recipe, to: input, grainPhase: 146), bounds: bounds)
        XCTAssertNotEqual(first, next, "Live grain must not remain stuck at screen coordinates")
        XCTAssertEqual(first, samples(FilterAdjustmentRenderer.apply(recipe, to: input, grainPhase: 73), bounds: bounds))
        let disabled = FilterAdjustments()
        XCTAssertEqual(samples(FilterAdjustmentRenderer.apply(disabled, to: input, grainPhase: 73), bounds: bounds), samples(FilterAdjustmentRenderer.apply(disabled, to: input, grainPhase: 146), bounds: bounds))
    }
    func testAberrationGrowsSmoothlyAndHasClearlyVisibleMaximum() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 720)
        let black = CIImage(color: .black).cropped(to: bounds)
        let stripe = CIImage(color: .white).cropped(to: CGRect(x: 800, y: 0, width: 8, height: 720)).composited(over: black)
        var separations: [Double] = []
        for value in [0.0, 25, 50, 75, 100] {
            var recipe = FilterAdjustments(); recipe[.aberration] = value
            let output = FilterAdjustmentRenderer.apply(recipe, to: stripe)
            let row = samples(output, bounds: CGRect(x: 0, y: 360, width: 1000, height: 1))
            func center(_ channel: Int) -> Double {
                var total = 0.0, weighted = 0.0
                for x in 0..<1000 { let v = Double(row[x * 4 + channel]); total += v; weighted += Double(x) * v }
                return weighted / max(total, 0.001)
            }
            separations.append(abs(center(0) - center(2)))
            let image = try XCTUnwrap(context.createCGImage(output, from: bounds))
            let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = "Aberration-\(Int(value))"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(separations[0], 0, accuracy: 0.1)
        XCTAssertGreaterThan(separations[4], 20, "Maximum must produce obvious color separation")
        for i in 1..<5 { XCTAssertGreaterThan(separations[i], separations[i-1]) }
        XCTAssertEqual(separations[4], separations[2] * 2, accuracy: 0.5)
    }
    func testGrainRespectsDensityHasNoGrayVeilAndEntersContinuously() {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        func stats(_ level: CGFloat, size: Double) -> (mean: Double, deviation: Double) {
            let input = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: bounds)
            var recipe = FilterAdjustments(); recipe[.grainSize] = size
            let before = samples(input, bounds: bounds)
            let after = samples(FilterAdjustmentRenderer.apply(recipe, to: input), bounds: bounds)
            let diffs = stride(from: 0, to: before.count, by: 4).map { Double(after[$0] - before[$0]) }
            let mean = diffs.reduce(0, +) / Double(diffs.count)
            let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(diffs.count)
            return (mean, sqrt(variance))
        }
        let mid = stats(0.4, size: 100), black = stats(0, size: 100), white = stats(1, size: 100)
        XCTAssertGreaterThan(mid.deviation, 0.005)
        XCTAssertLessThan(abs(mid.mean), 0.003, "Grain must not lift the whole image like a gray overlay")
        XCTAssertLessThan(black.deviation, mid.deviation * 0.1)
        XCTAssertLessThan(white.deviation, mid.deviation * 0.1)
        XCTAssertLessThan(stats(0.4, size: 0.1).deviation, mid.deviation * 0.02)
    }
    func testGrainSaturationChangesChromaClearlyAndFadeHasStrongerLinearWarmth() {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: bounds)
        var chroma: [Double] = []
        for saturation in [0.0, 50, 100] {
            var settings = FilterAdjustments(); settings[.grainSize] = 80; settings[.grainSaturation] = saturation
            let output = samples(FilterAdjustmentRenderer.apply(settings, to: input, grainPhase: 19), bounds: bounds)
            let differences = stride(from: 0, to: output.count, by: 4).map { Double(abs(output[$0] - output[$0 + 2])) }
            chroma.append(differences.reduce(0, +) / Double(differences.count))
        }
        XCTAssertLessThan(chroma[0], 0.0001)
        XCTAssertGreaterThan(chroma[2], 0.04, "Maximum should make coloured grain visible on a neutral patch")
        XCTAssertGreaterThan(chroma[2], chroma[1] * 1.7)
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext()
        var warmth: [Float] = []
        for fade in [0.0, 50, 100] {
            var settings = FilterAdjustments(); settings[.fade] = fade
            let result = FilterAdjustmentRenderer.apply(settings, to: input)
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { context.render(result, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace) }
            warmth.append(pixel[0] - pixel[2])
        }
        XCTAssertGreaterThan(warmth[2], 0.10)
        XCTAssertEqual(warmth[2], warmth[1] * 2, accuracy: 0.002)
    }

    func testHalationCreatesWarmEdgeSpillAndKeepsDistantShadowsClean() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 1200)
        let base = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: bounds)
        let light = CIImage(color: .white).cropped(to: CGRect(x: 480, y: 480, width: 240, height: 240))
        let input = light.composited(over: base)
        var recipe = FilterAdjustments(); recipe[.halation] = 100
        let output = FilterAdjustmentRenderer.apply(recipe, to: input)
        let point = CGRect(x: 476, y: 600, width: 1, height: 1)
        let before = samples(input, bounds: point), after = samples(output, bounds: point)
        XCTAssertGreaterThan(after[0] - before[0], 0.01)
        XCTAssertGreaterThan(after[0] - before[0], after[1] - before[1])
        let far = CGRect(x: 100, y: 100, width: 1, height: 1)
        XCTAssertEqual(samples(input, bounds: far)[0], samples(output, bounds: far)[0], accuracy: 0.001)
        for parameter in [FilterParameter.grainSize, .halation] {
            for value in [0.0, 50, 100] {
                var recipe = FilterAdjustments(); recipe[parameter] = value
                let result = FilterAdjustmentRenderer.apply(recipe, to: input)
                let cg = try XCTUnwrap(context.createCGImage(result, from: bounds))
                let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "texture-\(parameter.rawValue)-\(Int(value))"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}

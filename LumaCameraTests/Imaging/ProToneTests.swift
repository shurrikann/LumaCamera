import XCTest
import CoreImage
import ImageIO
@testable import LumaCamera

final class ProToneTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false])
    private func source(_ level: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level, alpha: 1, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    private func sample(_ image: CIImage) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        p.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space) }
        return p
    }
    func testCurvesRemainMonotonicNeutralAndRetainExtendedHighlights() {
        XCTAssertNotNil(MetalImageKernels.color("proTone"))
        for tone in PhotoTone.allCases {
            var previous: Float = -1
            for level: CGFloat in [0, 0.001, 0.01, 0.05, 0.18, 0.5, 0.99, 1, 1.01, 2, 4, 8] {
                let value = sample(tone.apply(to: source(level)))
                XCTAssertTrue(value.allSatisfy(\.isFinite), tone.rawValue)
                XCTAssertGreaterThanOrEqual(value[0] + 0.0001, previous)
                XCTAssertEqual(value[0], value[1], accuracy: 0.001)
                XCTAssertEqual(value[1], value[2], accuracy: 0.001)
                if level >= 2 { XCTAssertGreaterThan(value[0], 1, "HDR highlights must not flatten to SDR white") }
                previous = value[0]
            }
        }
    }
    func testReferenceDirectionsAndNaturalBaseline() {
        let black = source(0), mid = source(0.18)
        XCTAssertGreaterThan(sample(PhotoTone.cinematic.apply(to: black))[0], 0.002)
        XCTAssertLessThan(sample(PhotoTone.contrast.apply(to: mid))[0], 0.15)
        XCTAssertGreaterThan(sample(PhotoTone.bright.apply(to: mid))[0], 0.25)
        XCTAssertEqual(sample(PhotoTone.natural.apply(to: mid))[0], 0.18, accuracy: 0.001)
        for tone in PhotoTone.allCases {
            let curve = tone.curve
            XCTAssertEqual(curve.count, 5)
            XCTAssertTrue(zip(curve, curve.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }
    func testHDRBrightToneKeepsBlackAndUsesRestrainedMidtoneLift() {
        let black = sample(PhotoTone.bright.apply(to: source(0), hdr: true))[0]
        let naturalMid = sample(PhotoTone.natural.apply(to: source(0.18), hdr: true))[0]
        let brightMid = sample(PhotoTone.bright.apply(to: source(0.18), hdr: true))[0]
        XCTAssertEqual(black, 0, accuracy: 0.0001, "HDR清新明亮不能抬黑造成泛白")
        XCTAssertGreaterThan(brightMid, naturalMid)
        XCTAssertLessThan(brightMid, 0.26, "HDR中灰只应轻抬，不能沿用SDR的大幅平坦化曲线")
        XCTAssertEqual(sample(PhotoTone.bright.apply(to: source(0)))[0], 0.02 / 12.92, accuracy: 0.0001,
                       "SDR清新明亮保留轻微抬黑")
    }

    func testHDRProTonePairKeepsContinuousHighlightsAndUsesSeparateBlackPoints() throws {
        for tone in [PhotoTone.cinematic, .contrast, .bright] {
            let look = CaptureLook(tone: tone)
            let levels: [CGFloat] = [0, 0.005, 0.05, 0.18, 0.5, 0.65, 0.8, 0.99, 1, 1.01, 2, 4, 8]
            let outputs = try levels.map { level in
                sample(try XCTUnwrap(Imaging.filteredHDR(source(level), look: look)).hdr)[0]
            }
            XCTAssertTrue(zip(outputs, outputs.dropFirst()).allSatisfy { $0 <= $1 }, tone.rawValue)
            for (input, output) in zip(levels, outputs) where input >= 1 {
                XCTAssertEqual(output, Float(input), accuracy: 0.002)
            }
            let black = try XCTUnwrap(Imaging.filteredHDR(source(0), look: look))
            if tone == .cinematic || tone == .bright {
                XCTAssertLessThan(sample(black.hdr)[0], sample(black.sdr)[0])
            }

            // 彩色灯光高光保留 RGB 比例，避免全局饱和度作用到参考白以上。
            let lamp = CIImage(color: CIColor(red: 4, green: 2, blue: 0.6, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            let hdrLamp = try XCTUnwrap(Imaging.filteredHDR(lamp, look: look)).hdr
            for (actual, expected) in zip(sample(hdrLamp), sample(lamp)) {
                XCTAssertEqual(actual, expected, accuracy: 0.002)
            }
        }
    }
    #if !targetEnvironment(simulator)
    func testEachToneIsEncodedInTenBitHDRHEIFWithoutSavingToPhotos() throws {
        let base = source(0.18)
        let highlight = source(4).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let input = highlight.composited(over: base)
        var renderedMidtones: [Float] = []
        for tone in PhotoTone.allCases {
            let photo = try PhotoEncoder.encode(source: input, raw: nil, look: CaptureLook(tone: tone),
                options: PhotoOptions(format: .heifPro, hdr: true), context: context)
            let resource = try XCTUnwrap(photo.resources.first)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(resource.data as CFData, nil))
            HDRImageAssertions.assertHDR(source, "PRO-TONE HDR")
            let decoded = try XCTUnwrap(CIImage(data: resource.data, options: [.expandToHDR: true]))
            XCTAssertGreaterThan(sample(decoded)[0], 1)
            let midtone = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.width * 0.75, y: 0))
            renderedMidtones.append(sample(midtone)[0])
        }
        XCTAssertLessThan(renderedMidtones[2], renderedMidtones[0])
        XCTAssertGreaterThan(renderedMidtones[3], renderedMidtones[0])
    }
    #endif
}

import CoreImage
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import XCTest
@testable import LumaCamera

final class AstroSyntheticSequenceTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: AstroSyntheticScene.colorSpace,
        .workingFormat: CIFormat.RGBAh
    ])

    func testSubpixelTranslationRotationAndBlankFrame() throws {
        var scene = AstroSyntheticScene()
        scene.readNoise = 0
        scene.shotNoise = 0
        let reference = scene.frame(0)
        let motions = [scene.motion(dx: -2.35, dy: 3.45, rotation: 0),
                       scene.motion(dx: 0, dy: 0, rotation: 0.027),
                       scene.motion(dx: 8.1, dy: -7.3, rotation: -0.034)]
        var errors: [Double] = []
        var timings: [Double] = []
        for (index, transform) in motions.enumerated() {
            let frame = scene.frame(index + 1, motion: transform)
            let start = CACurrentMediaTime()
            let result = try XCTUnwrap(AstroStarRegistration.rigidTransform(reference: reference, frame: frame, context: context))
            timings.append((CACurrentMediaTime() - start) * 1000)
            for star in scene.stars {
                let recovered = star.position.applying(transform).applying(result)
                errors.append(hypot(recovered.x - star.position.x, recovered.y - star.position.y))
            }
        }
        let p95 = percentile(errors, 0.95)
        XCTAssertLessThan(p95, 0.5)
        scene.stars = []
        XCTAssertNil(AstroStarRegistration.rigidTransform(reference: reference, frame: scene.frame(4), context: context))
        print("ASTRO-SYNTH-REGISTER stars=\(errors.count) p95px=\(p95) milliseconds=\(timings)")
    }

    func testNineFrameProductionStackAndEncode() throws {
        var scene = AstroSyntheticScene()
        scene.includesGround = true
        scene.hotPixels = [CGPoint(x: 222, y: 226)]
        scene.satellites = [.init(start: CGPoint(x: 155, y: 330.5), end: CGPoint(x: 319, y: 330.5), frames: [4])]
        var clean = scene
        clean.shotNoise = 0
        clean.readNoise = 0
        clean.hotPixels = []
        clean.satellites = []

        var stack = AstroPhotoStackProcessor(context: context, linearSpace: AstroSyntheticScene.colorSpace)
        XCTAssertNil(stack.finishedImage(iso: 1600))
        let start = CACurrentMediaTime()
        let ground = CGRect(x: 112, y: 16, width: 48, height: 16)
        let first = scene.frame(0)
        var groundFrames = [luma(first, in: ground)]
        XCTAssertTrue(stack.append(first))
        for i in 1..<9 {
            let t = CGFloat(i)
            let motion = scene.motion(dx: t * 1.65, dy: t * -0.53, rotation: t * 0.002)
            let frame = scene.frame(i, motion: motion, exposure: i.isMultiple(of: 2) ? 1.01 : 0.99)
            groundFrames.append(luma(frame, in: ground))
            XCTAssertTrue(stack.append(frame))
        }
        XCTAssertEqual(stack.acceptedFrames, 9)
        XCTAssertEqual(stack.groupCounts, [3, 3, 3])
        let stacked = try XCTUnwrap(stack.stackedImage())
        let final = try XCTUnwrap(stack.finishedImage(iso: 1600))
        let cleanReference = clean.frame(0)

        let sky = CGRect(x: 155, y: 242, width: 48, height: 44)
        let baselineSky = luma(cleanReference, in: sky)
        let noiseBefore = spread(zip(luma(first, in: sky), baselineSky).map { $0 - $1 })
        let noiseAfter = spread(zip(luma(stacked, in: sky), baselineSky).map { $0 - $1 })
        let noiseRatio = noiseAfter / noiseBefore
        let line = CGRect(x: 170, y: 329, width: 135, height: 3)
        let lineResidual = zip(luma(stacked, in: line), luma(cleanReference, in: line)).map { $0 - $1 }
        let residualSigma = percentile(lineResidual, 0.99) / noiseBefore

        let star = CGRect(x: 281, y: 99, width: 11, height: 11)
        let inputStar = luma(cleanReference, in: star)
        let outputStar = luma(stacked, in: star)
        let localSky = Double(clean.skyLevel + clean.skyGradient * 104.5 / 511)
        let flux = { (pixels: [Double]) in pixels.reduce(0) { $0 + max(0, $1 - localSky) } }
        let fluxRatio = flux(outputStar) / flux(inputStar)
        let peakRatio = (outputStar.max() ?? 0) / (inputStar.max() ?? 1)
        let hotPixel = luma(stacked, in: CGRect(x: 222, y: 226, width: 1, height: 1))[0]
        let hotInput = luma(first, in: CGRect(x: 222, y: 226, width: 1, height: 1))[0]
        let cleanGround = luma(cleanReference, in: ground)
        let finishedGround = luma(final, in: ground)
        // The fixture moves the sky while keeping the ground at fixed coordinates.
        // Reference the same noisy frames stacked without registration or sky processing.
        let groundControls: [Double] = cleanGround.indices.map { pixel in
            var means: [Double] = []
            for group in 0..<3 {
                let values = stride(from: group, to: groundFrames.count, by: 3)
                    .map { groundFrames[$0][pixel] }
                means.append(values.reduce(0, +) / Double(values.count))
            }
            return means.sorted()[1]
        }
        func relativeGroundError(_ values: [Double], against reference: [Double]) -> Double {
            zip(values, reference).reduce(0) { $0 + abs($1.0 - $1.1) } / reference.reduce(0, +)
        }
        let relativeGroundChange = relativeGroundError(finishedGround, against: cleanGround)
        let groundControlNoise = relativeGroundError(groundControls, against: cleanGround)
        let groundProcessingDrift = relativeGroundError(finishedGround, against: groundControls)
        let matte = AstroSkyMatte.estimate(first, context: context)
        let groundMask = luma(matte.image, in: ground)
        let finishedStar = luma(final, in: star)
        let finalStarFluxRatio = flux(finishedStar) / flux(inputStar)
        let finalNoiseRatio = spread(zip(luma(final, in: sky), baselineSky).map { $0 - $1 }) / noiseBefore
        let flattened = AstroPostProcessor.flattenBackground(stacked, sky: matte.image)
        let flattenedStar = luma(flattened, in: star)
        let flattenedStarFluxRatio = flux(flattenedStar) / flux(inputStar)
        let finalPeakRatio = (finishedStar.max() ?? 0) / (inputStar.max() ?? 1)

        print("ASTRO-SYNTH-STACK accepted=\(stack.acceptedFrames) groups=\(stack.groupCounts) noiseRatio=\(noiseRatio) lineP99Sigma=\(residualSigma) starFluxRatio=\(fluxRatio) starPeakRatio=\(peakRatio) hotPixelBefore=\(hotInput) hotPixelAfter=\(hotPixel) groundRelativeMAE=\(relativeGroundChange) groundControlNoise=\(groundControlNoise) groundProcessingDrift=\(groundProcessingDrift) groundMaskMean=\(groundMask.reduce(0, +) / Double(groundMask.count)) flattenedStarFluxRatio=\(flattenedStarFluxRatio) finalStarFluxRatio=\(finalStarFluxRatio) finalNoiseRatio=\(finalNoiseRatio) peaks=\([inputStar.max() ?? 0, outputStar.max() ?? 0, flattenedStar.max() ?? 0, finishedStar.max() ?? 0]) finalPeakRatio=\(finalPeakRatio) milliseconds=\((CACurrentMediaTime() - start) * 1000)")
        XCTAssertLessThan(noiseRatio, 0.6)
        XCTAssertLessThan(residualSigma, 5)
        XCTAssertGreaterThan(fluxRatio, 0.9)
        XCTAssertGreaterThan(outputStar.max() ?? 0, 1)
        XCTAssertLessThan(hotPixel, hotInput * 0.5)
        XCTAssertGreaterThan(finalStarFluxRatio, 0.9)
        XCTAssertGreaterThan(finishedStar.max() ?? 0, 1)
        XCTAssertGreaterThan(finalPeakRatio, 0.9)
        XCTAssertLessThan(finalNoiseRatio, 0.6)
        XCTAssertNotNil(matte.groundROI)
        XCTAssertLessThan(groundMask.reduce(0, +) / Double(groundMask.count), 0.01)
        XCTAssertLessThan(groundProcessingDrift, 0.01)
        XCTAssertLessThan(relativeGroundChange, groundControlNoise + 0.01)

        let rendered = try XCTUnwrap(context.createCGImage(final, from: scene.extent))
        try checkEncodedImage(rendered, format: .jpg, aspect: 4.0 / 3, expectedHeight: 384)
        #if !targetEnvironment(simulator)
        try checkEncodedImage(rendered, format: .heif, aspect: 16.0 / 9, expectedHeight: 288)
        #endif

        stack.releaseFrames()
        XCTAssertNil(stack.stackedImage())
        XCTAssertEqual(stack.acceptedFrames, 9) // Remains available for metadata after releasing image buffers.
        stack.reset()
        XCTAssertTrue(stack.append(first))
        XCTAssertEqual(stack.groupCounts, [1, 0, 0])
    }

    func testSatelliteAcrossAllThreeGroups() throws {
        var scene = AstroSyntheticScene()
        scene.satellites = [.init(start: CGPoint(x: 155, y: 330.5), end: CGPoint(x: 319, y: 330.5), frames: [3, 4, 5])]
        var stack = AstroPhotoStackProcessor(context: context, linearSpace: AstroSyntheticScene.colorSpace)
        let region = CGRect(x: 170, y: 329, width: 135, height: 3)
        let start = CACurrentMediaTime()
        let reference = luma(scene.frame(0), in: region)
        var contaminated = [Double]()
        for i in 0..<9 {
            let frame = scene.frame(i)
            XCTAssertTrue(stack.append(frame))
            if i == 4 { contaminated = luma(frame, in: region) }
        }
        XCTAssertEqual(stack.groupCounts, [3, 3, 3])
        let output = luma(try XCTUnwrap(stack.stackedImage()), in: region)
        let before = percentile(zip(contaminated, reference).map { $0 - $1 }, 0.99)
        let after = percentile(zip(output, reference).map { $0 - $1 }, 0.99)
        XCTAssertGreaterThan(before, 0.3)
        XCTAssertLessThan(after, before * 0.2)
        print("ASTRO-SYNTH-SATELLITE frames=3 acrossGroups=3 lineP99Before=\(before) lineP99After=\(after) milliseconds=\((CACurrentMediaTime() - start) * 1000)")
    }

    func testTrailMotionWithRotationAndDroppedFrame() {
        var scene = AstroSyntheticScene()
        scene.shotNoise = 0
        scene.readNoise = 0
        let sky = CIImage(color: .white).cropped(to: scene.extent)
        var motion = AstroTrailMotion()
        for i in [0, 1, 2, 3, 5, 6, 7, 8] {
            let transform = scene.motion(dx: 0, dy: 0, rotation: CGFloat(i) * 0.006, pivot: CGPoint(x: 15, y: 16))
            motion.observe(scene.frame(i, motion: transform), sky: sky, time: Double(i), context: context)
        }
        XCTAssertEqual(motion.maximumGap, 2)
        XCTAssertLessThan(motion.velocity.x, -0.4)
        XCTAssertGreaterThan(motion.velocity.y, 0.4)
        print("ASTRO-SYNTH-TRAIL samples=8 observedGapSeconds=\(motion.maximumGap) velocity=\(motion.velocity)")
    }

    private func checkEncodedImage(_ image: CGImage, format: AstroImageFormat, aspect: Double,
                                   expectedHeight: Int) throws {
        let data = try XCTUnwrap(AstroImageEncoder.encode(image, options:
            AstroImageOptions(format: format, aspect: aspect, mode: "星空照片", frameCount: 9,
                              exposureSeconds: 2, iso: 1600, lensName: "Synthetic fixture",
                              focalLengthMM: 6.5, focalLength35mm: 24)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, format.utType.identifier)
        let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(info[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, expectedHeight)
        XCTAssertEqual(info[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime] as? Double, 2)
        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], [1600])
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLength] as? Double, 6.5)
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, 24)
        let tiff = try XCTUnwrap(info[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFSoftware] as? String, "LumaCamera")
        let comment = exif[kCGImagePropertyExifUserComment] as? String
        XCTAssertEqual(comment, "Luma Astro Photo | 9 frames | 2s | ISO 1600")
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let description = CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description[x-default]" as CFString) as String?
        XCTAssertEqual(description, "Luma 星空照片 · 9 帧 · 2s · ISO 1600")
        print("ASTRO-SYNTH-ENCODE type=\(format.rawValue) width=512 height=\(expectedHeight) EXIF=\(comment ?? "") XMP=\(description ?? "")")
    }

    private func luma(_ image: CIImage, in box: CGRect) -> [Double] {
        let width = Int(box.width), height = Int(box.height)
        var data = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 16, bounds: box,
                       format: .RGBAf, colorSpace: AstroSyntheticScene.colorSpace)
        return stride(from: 0, to: data.count, by: 4).map { index in
            0.2126 * Double(data[index]) + 0.7152 * Double(data[index + 1]) + 0.0722 * Double(data[index + 2])
        }
    }

    private func spread(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
    }

    private func percentile(_ values: [Double], _ percent: Double) -> Double {
        values.sorted()[Int(ceil(Double(values.count) * percent)) - 1]
    }
}

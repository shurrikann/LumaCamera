import XCTest
import CoreImage
import CoreGraphics
import QuartzCore
import ImageIO
@testable import LumaCamera

final class PortraitDepthControlTests: XCTestCase {
    func testFaceProtectionRepairsMaskHoleAndPreservesBackgroundBlur() throws {
        let extent = CGRect(x: 20, y: 30, width: 900, height: 1200)
        let checker = CIFilter.checkerboardGenerator()
        checker.width = 5; checker.sharpness = 1
        let image = try XCTUnwrap(checker.outputImage).cropped(to: extent)
        let broken = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 90, height: 120))
        let face = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.3)
        let protected = PortraitPhotoRenderer.faceProtectedMask(broken, image: image, faceRects: [face])
        let output = PortraitPhotoRenderer.apply(image, foregroundMask: protected, radius: 8.8)
        let context = CIContext()
        func pixels(_ source: CIImage, rect: CGRect) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
            context.render(source, toBitmap: &bytes, rowBytes: Int(rect.width) * 4, bounds: rect,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes
        }
        let cheek = CGRect(x: 620, y: 420, width: 20, height: 20)
        XCTAssertEqual(pixels(image, rect: cheek), pixels(output, rect: cheek), "蒙版漏分的脸部内部必须保留原片像素")
        let background = CGRect(x: 60, y: 1000, width: 20, height: 20)
        XCTAssertNotEqual(pixels(image, rect: background), pixels(output, rect: background), "背景仍要虚化")
        XCTAssertTrue(PortraitPhotoRenderer.faceProtectedMask(broken, image: image, faceRects: []) === broken)
    }

    func testHeadRepairProtectsCrownAndOuterGlassesWithoutClearingBackground() throws {
        let extent = CGRect(x: 0, y: 0, width: 900, height: 1200)
        let black = CIImage(color: .black).cropped(to: extent)
        let head = CGRect(x: 270, y: 380, width: 360, height: 500)
        let semantic = CIImage(color: .white).cropped(to: CGRect(x: 620, y: 660, width: 35, height: 35))
            .composited(over: CIImage(color: .white).cropped(to: head)).composited(over: black)
        let image = CIImage(color: .gray).cropped(to: extent)
        let box = CGRect(x: 0.4, y: 0.35, width: 0.3, height: 0.25)
        let faceOnly = PortraitPhotoRenderer.faceProtectedMask(black, image: image, faceRects: [box])
        let repaired = PortraitPhotoRenderer.faceProtectedMask(black, image: image, headMask: semantic, faceRects: [box])
        let context = CIContext()
        func red(_ mask: CIImage, x: Int, y: Int) throws -> UInt8 {
            let cg = try XCTUnwrap(context.createCGImage(mask, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let data = try XCTUnwrap(cg.dataProvider?.data)
            return CFDataGetBytePtr(data)![(1199 - y) * cg.bytesPerRow + x * 4]
        }
        XCTAssertLessThan(try red(faceOnly, x: 450, y: 850), 5)
        XCTAssertGreaterThan(try red(repaired, x: 450, y: 850), 250, "头顶不能依赖脸框椭圆")
        XCTAssertGreaterThan(try red(repaired, x: 645, y: 680), 250, "眼镜外角应保持清晰")
        XCTAssertLessThan(try red(repaired, x: 200, y: 1000), 5, "背景不能因大头框整体变清晰")
    }

    func testHeadRepairRemovesFalseForegroundLeafButKeepsBodyAndHair() throws {
        let extent = CGRect(x: 0, y: 0, width: 900, height: 1200)
        let black = CIImage(color: .black).cropped(to: extent)
        let leaf = CGRect(x: 650, y: 500, width: 50, height: 50)
        let body = CGRect(x: 250, y: 0, width: 400, height: 350)
        let bad = CIImage(color: .white).cropped(to: leaf)
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 620, y: 660, width: 35, height: 35)))
            .composited(over: CIImage(color: .white).cropped(to: body)).composited(over: black)
        let semantic = CIImage(color: .white).cropped(to: CGRect(x: 270, y: 380, width: 360, height: 500))
            .composited(over: black)
        let image = CIImage(color: .gray).cropped(to: extent)
        let output = PortraitPhotoRenderer.faceProtectedMask(bad, image: image, headMask: semantic,
            faceRects: [CGRect(x: 0.4, y: 0.35, width: 0.3, height: 0.25)])
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let data = try XCTUnwrap(cg.dataProvider?.data), bytes = CFDataGetBytePtr(data)!
        func value(_ x: Int, _ y: Int) -> UInt8 { bytes[(1199 - y) * cg.bytesPerRow + x * 4] }
        XCTAssertLessThan(value(670, 525), 5, "头部附近误纳入的绿叶必须恢复为背景")
        XCTAssertGreaterThan(value(450, 850), 250, "头发漏分仍要修补")
        XCTAssertGreaterThan(value(450, 150), 250, "头部区域外不能撤掉身体前景")
        XCTAssertGreaterThan(value(645, 680), 250, "语义分割漏掉外镜框时需保留原蒙版眼部细节")
    }
    func testBlurSliderMapsFromSharpToStrongerBlur() {
        XCTAssertEqual(PortraitPhotoRenderer.normalizedStrength(-1), 0)
        XCTAssertEqual(PortraitPhotoRenderer.normalizedStrength(1.5), 1)
        XCTAssertEqual(PortraitPhotoRenderer.normalizedStrength(.infinity), 0.5)
        XCTAssertEqual(PortraitPhotoRenderer.normalizedStrength(.nan), 0.5)
        XCTAssertEqual(PortraitPhotoRenderer.blurRadius(for: 0), 0)
        XCTAssertEqual(PortraitPhotoRenderer.blurRadius(for: 0.5), 4.4, accuracy: 0.0001)
        XCTAssertEqual(PortraitPhotoRenderer.blurRadius(for: 1), 8.8, accuracy: 0.0001)
        XCTAssertEqual(PortraitPhotoRenderer.blurRadius(for: 2), 8.8, accuracy: 0.0001)
        XCTAssertEqual(PortraitPhotoRenderer.blurRadius(for: -.infinity), 4.4, accuracy: 0.0001)
        XCTAssertEqual(PortraitPhotoRenderer.maximumBlurRadius / 22, 0.4, accuracy: 0.0001,
                       "The new full-slider blur cap should be 40% of the previous radius.")
    }

    func testPreviewProcessorInvalidatesMaskWhenPortraitStops() {
        let processor = PortraitPreviewProcessor()
        processor.configure(enabled: true, generation: 1)
        processor.configure(enabled: false, generation: 2)
        XCTAssertNil(processor.latestMask(generation: 1))
        XCTAssertNil(processor.latestMask(generation: 2))
        XCTAssertEqual(PortraitPreviewProcessor.minimumInterval, 0.10, accuracy: 0.0001)
        XCTAssertEqual(PortraitPreviewProcessor.maximumMaskAge, 0.55, accuracy: 0.0001)
    }

    func testPreviewMaskSurvivesTransientSegmentationMissesDuringSliderDrag() throws {
        let processor = PortraitPreviewProcessor()
        processor.configure(enabled: true, generation: 1)
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        let start = CACurrentMediaTime()
        processor.recordSegmentationResultForTesting(mask, completedAt: start, generation: 1)

        // 滑块连续更新时处理器会反复收到相同配置；这些更新不应抹掉当前有效蒙版。
        for _ in 0..<100 { processor.configure(enabled: true, generation: 1) }
        XCTAssertNotNil(processor.latestMask(generation: 1, now: start + 0.05))

        processor.recordSegmentationResultForTesting(nil, completedAt: start + 0.16, generation: 1)
        XCTAssertNotNil(processor.latestMask(generation: 1, now: start + 0.17),
                         "One missed segmentation frame must not flash the preview back to sharp.")
        processor.recordSegmentationResultForTesting(nil, completedAt: start + 0.32, generation: 1)
        XCTAssertNotNil(processor.latestMask(generation: 1, now: start + 0.33),
                         "Two consecutive misses remain within the temporal tolerance window.")
        processor.recordSegmentationResultForTesting(nil, completedAt: start + 0.48, generation: 1)
        XCTAssertEqual(try XCTUnwrap(processor.latestSnapshot(generation: 1, now: start + 0.49)).visibility, 0.3, accuracy: 0.001)
        XCTAssertNil(processor.latestMask(generation: 1, now: start + 0.56),
                     "持续丢失人物后淡出虚化，不能无限保留过期蒙版。")
    }

    func testStrengthChangesConvergeWithoutResettingMask() throws {
        let processor = PortraitPreviewProcessor()
        processor.configure(enabled: true, generation: 1)
        XCTAssertEqual(processor.smoothStrength(0, generation: 1, now: 10), 0)
        let first = processor.smoothStrength(1, generation: 1, now: 10.016)
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 0.5)
        var previous = first
        for frame in 2...12 {
            let next = processor.smoothStrength(1, generation: 1, now: 10 + Double(frame) * 0.016)
            XCTAssertGreaterThanOrEqual(next, previous)
            previous = next
        }
        XCTAssertGreaterThan(previous, 0.98)
        processor.configure(enabled: false, generation: 2)
        XCTAssertEqual(processor.smoothStrength(1, generation: 1, now: 11), 0)
    }

    func testBlurAppearanceScalesWithImageResolutionAndMeasuresRendering() throws {
        let extent = CGRect(x: 0, y: 0, width: 900, height: 600)
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = .black; checker.color1 = .white
        checker.width = 9; checker.sharpness = 1
        let source = try XCTUnwrap(checker.outputImage?.cropped(to: extent))
        let mask = CIImage(color: .black).cropped(to: extent)
        let preview = PortraitPhotoRenderer.applyPreview(source, foregroundMask: mask, radius: 8.8)
        let photo = PortraitPhotoRenderer.apply(source.transformed(by: CGAffineTransform(scaleX: 2, y: 2)),
            foregroundMask: mask.transformed(by: CGAffineTransform(scaleX: 2, y: 2)), radius: 8.8)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let context = CIContext(options: [.cacheIntermediates: false])
        let difference = photo.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: preview])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var mean = [Float](repeating: 0, count: 4)
        context.render(difference, toBitmap: &mean, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        XCTAssertLessThan(max(mean[0], mean[1], mean[2]), 0.02,
            "成片等比缩回预览后虚化强度应一致，不能因为像素更多而显得过弱")

        // 真正触发渲染并等待完成，不把构造惰性 CIImage 图耗时当作预览帧率。
        let fullExtent = CGRect(x: 0, y: 0, width: 900, height: 1200)
        let image = source.clampedToExtent().cropped(to: fullExtent)
        let personMask = CIImage(color: .white).cropped(to: CGRect(x: 200, y: 200, width: 400, height: 800))
            .composited(over: CIImage(color: .black).cropped(to: fullExtent))
        var samples: [Double] = []
        for index in 0..<24 {
            let start = CACurrentMediaTime()
            let output = PortraitPhotoRenderer.applyPreview(image, foregroundMask: personMask,
                radius: Float(index % 9))
            let rendered = context.createCGImage(output, from: fullExtent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
            XCTAssertNotNil(rendered)
            if index >= 4 { samples.append((CACurrentMediaTime() - start) * 1000) }
        }
        samples.sort()
        print("PORTRAIT-RENDER device=physical samples=20 size=900x1200 medianMS=\(samples[10]) p95MS=\(samples[18]) maxMS=\(samples.last ?? 0) scaledMeanDifference=\(mean)")
        XCTAssertLessThan(samples[18], 100, "定向渲染出现明显退化；该指标不是屏幕 FPS")
    }

    func testNormalizedBackgroundBlurPreservesForegroundAndAvoidsColorHalo() throws {
        let extent = CGRect(x: 0, y: 0, width: 900, height: 400)
        let personRect = CGRect(x: 0, y: 0, width: 450, height: 400)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)
        let person = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: personRect)
        let image = person.composited(over: background)
        let black = CIImage(color: .black).cropped(to: extent)
        let mask = CIImage(color: .white).cropped(to: personRect).composited(over: black)
        let output = PortraitPhotoRenderer.apply(image, foregroundMask: mask, radius: 8.8)
        let context = CIContext()
        func pixel(_ x: Int) -> [UInt8] {
            var value = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: x, y: 200, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return value
        }
        XCTAssertGreaterThan(pixel(430)[0], 250, "人物内部必须保持清晰红色")
        XCTAssertLessThan(pixel(455)[0], 8, "背景边缘不能卷入人物红色形成光晕")
        XCTAssertGreaterThan(pixel(455)[2], 245)
        // 弱虚化不能使用比模糊半径还宽的取样排除圈，否则边缘会出现黑线。
        let weak = PortraitPhotoRenderer.apply(image, foregroundMask: mask, radius: 0.01)
        var weakPixel = [UInt8](repeating: 0, count: 4)
        context.render(weak, toBitmap: &weakPixel, rowBytes: 4, bounds: CGRect(x: 451, y: 200, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertGreaterThan(weakPixel[2], 245, "低强度边缘不能发黑")
        let clear = PortraitPhotoRenderer.apply(image, foregroundMask: mask, radius: 0)
        XCTAssertTrue(clear === image)
    }

    func testPhotoEncoderBakesSelectedBlurStrengthIntoProcessedImage() throws {
        let width = 96
        let height = 72
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        checker.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        checker.center = CGPoint(x: width / 2, y: height / 2)
        checker.width = 4
        checker.sharpness = 1
        let source = try XCTUnwrap(checker.outputImage?.cropped(to: extent)).settingProperties([
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: 0.01,
                kCGImagePropertyExifISOSpeedRatings as String: [400],
                kCGImagePropertyExifFocalLength as String: 6.765]])

        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        // CIImage mask semantics are white = foreground for our renderer, which
        // is inverted before masked blur. Keep this fixture entirely background
        // so the cropped 4:3 output always includes pixels affected by the blur.
        for offset in stride(from: 3, to: maskPixels.count, by: 4) {
            maskPixels[offset] = 255
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let mask = CIImage(bitmapData: Data(maskPixels), bytesPerRow: width * 4,
                           size: CGSize(width: width, height: height), format: .RGBA8,
                           colorSpace: colorSpace)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        func encoded(strength: Double) throws -> Data {
            var options = PhotoOptions()
            options.format = .jpeg
            options.portraitMode = true
            options.portraitBlurStrength = strength
            let photo = try PhotoEncoder.encode(source: source, raw: nil, look: CaptureLook(),
                                                options: options, context: context, portraitMask: mask)
            return try XCTUnwrap(photo.resources.first?.data)
        }

        let sharp = try encoded(strength: 0)
        let blurred = try encoded(strength: 1)
        XCTAssertNotEqual(sharp, blurred, "The selected portrait blur strength must affect the saved JPEG pixels.")
        for data in [sharp, blurred] {
            let file = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifExposureTime as String] as? Double, 0.01)
            XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings as String])
            XCTAssertNotNil(exif[kCGImagePropertyExifFocalLength as String])
        }
    }

    func testPreviewRefinesPersonMaskBeforeApplyingBlur() throws {
        let width = 900
        let height = 300
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        checker.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        checker.center = CGPoint(x: width / 2, y: height / 2)
        checker.width = 3
        checker.sharpness = 1
        let source = try XCTUnwrap(checker.outputImage?.cropped(to: extent))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) { pixels[pixel * 4 + 3] = 255 }
        for y in 0..<height {
            for x in 0..<(width / 2) {
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let mask = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
                           size: CGSize(width: width, height: height), format: .RGBA8,
                           colorSpace: colorSpace)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let hardEdge = PortraitPhotoRenderer.apply(source, foregroundMask: mask, radius: 22)
        let refinedEdge = PortraitPhotoRenderer.applyPreview(source, foregroundMask: mask, radius: 22)
        let hardImage = try XCTUnwrap(context.createCGImage(hardEdge, from: extent))
        let refinedImage = try XCTUnwrap(context.createCGImage(refinedEdge, from: extent))
        let hardBytes = try XCTUnwrap(hardImage.dataProvider?.data) as Data
        let refinedBytes = try XCTUnwrap(refinedImage.dataProvider?.data) as Data
        XCTAssertNotEqual(hardBytes, refinedBytes,
                          "实时预览应使用边缘扩展和羽化后的人物蒙版，减轻分割边缘突兀感。")
    }
}
